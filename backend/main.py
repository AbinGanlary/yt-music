"""Grooves backend: YouTube Music metadata + audio proxy for a PWA client.

Personal-use tool. Do not expose it to the public internet without APP_TOKEN set.
"""
import hmac
import logging
import mimetypes
import os
import random
import re
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Callable, Optional
from urllib.parse import parse_qs, urlparse

import httpx
from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import Response, StreamingResponse
from fastapi.staticfiles import StaticFiles
from ytmusicapi import YTMusic
from ytmusicapi.constants import SUPPORTED_LOCATIONS
from yt_dlp import YoutubeDL

# Windows registry mime types can mislabel .js as text/plain, which breaks ES modules.
mimetypes.add_type("text/javascript", ".js")
mimetypes.add_type("application/manifest+json", ".webmanifest")

APP_TOKEN = os.environ.get("APP_TOKEN", "")
CHUNK = 4 * 1024 * 1024  # googlevideo throttles open-ended ranges; serve capped 206s
FRONTEND = Path(__file__).resolve().parent.parent / "frontend"

# YouTube only offers two AAC tiers to signed-out clients (itag 140 ≈128 kbps, 139 ≈48 kbps).
# Safari can't play Opus-in-WebM everywhere, so we stay on m4a.
FORMATS = {
    "high": "bestaudio[ext=m4a]/bestaudio",
    "low": "bestaudio[ext=m4a][abr<=64]/worstaudio[ext=m4a]/worstaudio",
}

log = logging.getLogger("uvicorn.error")
app = FastAPI(title="grooves")

# The native iOS app loads its UI from capacitor://localhost and talks to this server cross-origin.
from fastapi.middleware.cors import CORSMiddleware  # noqa: E402

app.add_middleware(
    CORSMiddleware,
    allow_origin_regex=r"^(capacitor|ionic)://localhost$|^https?://localhost(:\d+)?$",
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
    expose_headers=["Content-Range", "Accept-Ranges", "Content-Length"],
    max_age=86400,
)
_yts: dict[Optional[str], YTMusic] = {None: YTMusic()}
_stream_cache: dict[tuple[str, str], dict] = {}
_cache: dict[str, tuple[float, object]] = {}
_client = httpx.AsyncClient(timeout=httpx.Timeout(20.0, read=60.0), follow_redirects=True)


def _yt(loc: Optional[str] = None) -> YTMusic:
    """YTMusic client for a country (affects charts, home and search results)."""
    loc = (loc or "").upper() or None
    if loc and loc not in SUPPORTED_LOCATIONS:
        loc = None
    if loc not in _yts:
        _yts[loc] = YTMusic(location=loc)
    return _yts[loc]


def _cached(key: str, ttl: int, fn: Callable):
    hit = _cache.get(key)
    if hit and hit[0] > time.time():
        return hit[1]
    val = fn()
    _cache[key] = (time.time() + ttl, val)
    return val


def auth(request: Request):
    if not APP_TOKEN:
        return
    given = request.headers.get("x-token") or request.query_params.get("token") or ""
    if not hmac.compare_digest(given.encode(), APP_TOKEN.encode()):
        raise HTTPException(401, "bad token")


def _thumb(t: dict) -> Optional[str]:
    thumbs = t.get("thumbnails") or t.get("thumbnail") or []
    return thumbs[-1]["url"] if thumbs else None


def _track(t: dict) -> dict:
    album = t.get("album")
    return {
        "videoId": t.get("videoId"),
        "title": t.get("title"),
        "artists": [a["name"] for a in (t.get("artists") or []) if a.get("name")],
        "artistIds": [a["id"] for a in (t.get("artists") or []) if a.get("id")],
        "album": album.get("name") if isinstance(album, dict) else album,
        "albumId": album.get("id") if isinstance(album, dict) else None,
        "duration": t.get("duration") or t.get("length"),
        "thumbnail": _thumb(t),
    }


def _tracks(items, fallback_thumb=None, album=None) -> list:
    out = []
    for t in items or []:
        if not t or not t.get("videoId"):
            continue
        tr = _track(t)
        tr["thumbnail"] = tr["thumbnail"] or fallback_thumb
        tr["album"] = tr["album"] or album
        out.append(tr)
    return out


def _coll(kind: str, cid: str, title: str, subtitle: str, thumb: Optional[str]) -> dict:
    return {"kind": kind, "id": cid, "title": title, "subtitle": subtitle, "thumbnail": thumb}


# ---------------------------------------------------------------- search & discovery
@app.get("/api/search", dependencies=[Depends(auth)])
def search(q: str, filter: str = "songs", limit: int = 25, loc: Optional[str] = None):
    f = None if filter == "all" else filter
    results = _yt(loc).search(q, filter=f, limit=limit)
    return _tracks(results)


@app.get("/api/genre", dependencies=[Depends(auth)])
def genre(q: str, loc: Optional[str] = None):
    """A genre / mood / style by name: its songs and playlists (the Mix tab)."""
    def build():
        yt = _yt(loc)
        songs = _tracks(yt.search(q, filter="songs", limit=25))
        playlists, seen = [], set()
        try:
            found = yt.search(q, filter="playlists", limit=16)
        except Exception:
            found = []
        for r in found:
            pid = (r.get("browseId") or r.get("playlistId") or "")
            pid = pid[2:] if pid.startswith("VL") else pid
            if pid and pid not in seen:
                seen.add(pid)
                playlists.append(_coll("playlist", pid, r.get("title") or "", r.get("author") or "", _thumb(r)))
        return {"songs": songs, "playlists": playlists[:16]}
    return _cached(f"genre:{q.lower()}:{loc}", 1200, build)


@app.get("/api/counterpart/{video_id}", dependencies=[Depends(auth)])
def counterpart(video_id: str, title: str = "", artist: str = "", dur: str = "", loc: Optional[str] = None):
    """The 'song' version of a music video (album art, clean title), found by searching songs; null when none matches."""
    import re

    def clean(x: str) -> str:
        x = re.sub(r"[(\[][^)\]]*(official|video|audio|lyric|visuali[sz]er|music video|hd|4k)[^)\]]*[)\]]", " ", x or "", flags=re.I)
        x = re.sub(r"\s*[|\-–]\s*(official.*|lyric.*|video.*)$", "", x, flags=re.I)
        return re.sub(r"\s+", " ", x).strip()

    def norm(x: str) -> str:
        return re.sub(r"[\W_]+", " ", clean(x).lower()).strip()

    def secs(d) -> int:
        m = re.match(r"^(?:(\d+):)?(\d+):(\d{2})$", str(d or ""))
        return int(m.group(1) or 0) * 3600 + int(m.group(2)) * 60 + int(m.group(3)) if m else 0

    first_artist = (artist or "").split(",")[0].strip()
    want, wa, wd = norm(title), norm(first_artist), secs(dur)
    if not want:
        return None

    def build():
        found = _tracks(_yt(loc).search(f"{clean(title)} {first_artist}".strip(), filter="songs", limit=6))
        best, top = None, 0
        for t in found:
            nt = norm(t["title"] or "")
            score = (3 if nt == want else 1 if nt and (nt in want or want in nt) else 0)
            score += 2 if any(norm(a) and wa and (wa in norm(a) or norm(a) in wa) for a in t["artists"]) else 0
            score += 2 if wd and t.get("duration") and abs(secs(t["duration"]) - wd) <= 6 else 0
            if score > top:
                best, top = t, score
        return best if top >= 4 else None

    return _cached(f"cp:{video_id}", 86400, build)


@app.get("/api/suggest", dependencies=[Depends(auth)])
def suggest(q: str, loc: Optional[str] = None):
    return _yt(loc).get_search_suggestions(q)[:8]


@app.get("/api/radio/{video_id}", dependencies=[Depends(auth)])
def radio(video_id: str, limit: int = 25, loc: Optional[str] = None):
    """YouTube Music's 'up next' radio for a song: the recommendation queue."""
    pl = _yt(loc).get_watch_playlist(videoId=video_id, radio=True, limit=limit)
    return _tracks(pl.get("tracks"))


@app.get("/api/home", dependencies=[Depends(auth)])
def home(loc: Optional[str] = None):
    sections = []
    for s in _yt(loc).get_home(limit=6):
        items = _tracks(s.get("contents"))
        if items:
            sections.append({"title": s.get("title"), "items": items})
    return sections


@app.get("/api/countries", dependencies=[Depends(auth)])
def countries():
    return sorted(SUPPORTED_LOCATIONS)


def _chart_artists(ch: dict) -> list:
    return [
        _coll("artist", a["browseId"], a.get("title", ""), a.get("subscribers") or "", _thumb(a))
        for a in (ch.get("artists") or []) if a.get("browseId")
    ]


@app.get("/api/charts", dependencies=[Depends(auth)])
def charts(country: str = "ZZ", loc: Optional[str] = None):
    def build():
        ch = _yt(loc).get_charts(country)
        pls = [
            _coll("playlist", p["playlistId"], p.get("title", ""), "Chart", _thumb(p))
            for p in (ch.get("videos") or []) if p.get("playlistId")
        ]
        return {"playlists": pls, "artists": _chart_artists(ch)}
    return _cached(f"charts:{country}:{loc}", 1800, build)


_trend_cache: dict[str, tuple[float, list]] = {}


@app.get("/api/trending", dependencies=[Depends(auth)])
def trending(country: str = "IN"):
    """First chart playlist for the country (e.g. 'Trending 20 India'), flattened to tracks."""
    hit = _trend_cache.get(country)
    if hit and hit[0] > time.time():
        return hit[1]
    playlists = _yt(country).get_charts(country).get("videos") or []
    out: list = []
    for pl in playlists[:2]:
        if not pl.get("playlistId"):
            continue
        tracks = _yt(country).get_playlist(pl["playlistId"], limit=25).get("tracks", [])
        out = _tracks(tracks)
        if out:
            break
    _trend_cache[country] = (time.time() + 1800, out)
    return out


@app.get("/api/explore", dependencies=[Depends(auth)])
def explore(loc: Optional[str] = None):
    def build():
        y = _yt(loc)
        ex = y.get_explore()
        releases = [
            _coll(
                "album", r["browseId"], r.get("title", ""),
                ", ".join(a["name"] for a in (r.get("artists") or []) if a.get("name")) or r.get("type", ""),
                _thumb(r),
            )
            for r in (ex.get("new_releases") or []) if r.get("browseId")
        ]
        moods = [
            {"section": sec, "items": [{"title": m["title"], "params": m["params"]} for m in items]}
            for sec, items in y.get_mood_categories().items()
        ]
        return {"newReleases": releases, "moods": moods}
    return _cached(f"explore:{loc}", 1800, build)


@app.get("/api/mood", dependencies=[Depends(auth)])
def mood(params: str, loc: Optional[str] = None):
    pls = _cached(f"mood:{params}:{loc}", 1800, lambda: _yt(loc).get_mood_playlists(params))
    return [
        _coll("playlist", p["playlistId"], p.get("title", ""), p.get("description") or "", _thumb(p))
        for p in pls[:40] if p.get("playlistId")
    ]


# ---------------------------------------------------------------- detail pages
@app.get("/api/album/{browse_id}", dependencies=[Depends(auth)])
def album(browse_id: str, loc: Optional[str] = None):
    a = _yt(loc).get_album(browse_id)
    thumb = _thumb(a)
    return {
        "kind": "album", "title": a.get("title"), "thumbnail": thumb,
        "subtitle": ", ".join(x["name"] for x in (a.get("artists") or []) if x.get("name")),
        "meta": " · ".join(str(x) for x in (a.get("year"), a.get("trackCount") and f"{a['trackCount']} songs", a.get("duration")) if x),
        "tracks": _tracks(a.get("tracks"), thumb, a.get("title")),
    }


@app.get("/api/playlist/{playlist_id}", dependencies=[Depends(auth)])
def playlist(playlist_id: str, loc: Optional[str] = None):
    p = _cached(f"pl:{playlist_id}:{loc}", 900, lambda: _yt(loc).get_playlist(playlist_id, limit=100))
    thumb = _thumb(p)
    return {
        "kind": "playlist", "title": p.get("title"), "thumbnail": thumb,
        "subtitle": (p.get("author") or {}).get("name", "") if isinstance(p.get("author"), dict) else "",
        "meta": f"{p['trackCount']} songs" if p.get("trackCount") else "",
        "tracks": _tracks(p.get("tracks"), thumb),
    }


@app.get("/api/artist/{browse_id}", dependencies=[Depends(auth)])
def artist(browse_id: str, loc: Optional[str] = None):
    y = _yt(loc)
    a = y.get_artist(browse_id)
    thumb = _thumb(a)
    songs = _tracks((a.get("songs") or {}).get("results"), thumb)
    albums = [
        _coll("album", x["browseId"], x.get("title", ""), x.get("year", ""), _thumb(x))
        for x in ((a.get("albums") or {}).get("results") or []) if x.get("browseId")
    ]
    return {
        "kind": "artist", "title": a.get("name"), "thumbnail": thumb,
        "subtitle": a.get("subscribers") and f"{a['subscribers']} subscribers" or "",
        "meta": "", "tracks": songs, "albums": albums,
        "radioVideoId": songs[0]["videoId"] if songs else None,
    }


@app.get("/api/artists/search", dependencies=[Depends(auth)])
def artists_search(q: str, loc: Optional[str] = None):
    res = _yt(loc).search(q, filter="artists", limit=12)
    return [
        _coll("artist", r["browseId"], r.get("artist") or r.get("title", ""), "", _thumb(r))
        for r in res if r.get("browseId")
    ]


# ---------------------------------------------------------------- personalised mix
def _artist_songs(browse_id: str, loc: Optional[str]) -> list:
    y = _yt(loc)
    a = y.get_artist(browse_id)
    out = _tracks((a.get("songs") or {}).get("results"), _thumb(a))
    rid = a.get("radioId")
    if rid:
        try:
            out += _tracks(y.get_watch_playlist(playlistId=rid, limit=20).get("tracks"))
        except Exception:
            pass
    return out


def _lang_songs(lang: str, loc: Optional[str]) -> list:
    return _tracks(_yt(loc).search(f"new {lang} songs", filter="songs", limit=20))


@app.get("/api/mix", dependencies=[Depends(auth)])
def mix(artists: str = "", langs: str = "", loc: Optional[str] = None):
    """Songs from the artists and languages the user picked, interleaved so no single source dominates."""
    aids = [a for a in artists.split(",") if a][:6]
    lgs = [l for l in langs.split(",") if l][:3]
    key = f"mix:{','.join(sorted(aids))}:{','.join(sorted(lgs))}:{loc}"

    def build():
        with ThreadPoolExecutor(6) as ex:
            futs = [ex.submit(_artist_songs, a, loc) for a in aids] + [ex.submit(_lang_songs, l, loc) for l in lgs]
        lists = []
        for f in futs:
            try:
                lists.append(f.result())
            except Exception:
                pass
        seen, out = set(), []
        for i in range(max((len(l) for l in lists), default=0)):
            for l in lists:
                if i < len(l) and l[i]["videoId"] not in seen:
                    seen.add(l[i]["videoId"])
                    out.append(l[i])
        head, tail = out[:6], out[6:]
        random.shuffle(tail)          # keep each source's best song up front, shuffle the rest
        return (head + tail)[:40]
    return _cached(key, 1200, build)


@app.get("/api/langs", dependencies=[Depends(auth)])
def langs(lang: str, loc: Optional[str] = None):
    return _cached(f"lang:{lang}:{loc}", 1800, lambda: _lang_songs(lang, loc))


# ---------------------------------------------------------------- images, lyrics
IMG_HOSTS = ("googleusercontent.com", "ytimg.com", "ggpht.com")


@app.get("/api/img", dependencies=[Depends(auth)])
async def img(u: str, s: int = 544):
    """Same-origin thumbnail proxy so the service worker can cache art for offline use."""
    parts = urlparse(u)
    host = (parts.hostname or "").lower()
    if parts.scheme != "https" or not any(host == d or host.endswith("." + d) for d in IMG_HOSTS):
        raise HTTPException(400, "host not allowed")
    s = max(16, min(s, 1200))
    if "googleusercontent.com" in host or "ggpht.com" in host:
        u = re.sub(r"=[ws]\d+(-h\d+)?.*$", f"=w{s}-h{s}-l90-rj", u)
    r = await _client.get(u, follow_redirects=False)
    if r.status_code != 200:
        raise HTTPException(502, "image fetch failed")
    return Response(
        r.content,
        media_type=r.headers.get("content-type", "image/jpeg"),
        headers={"Cache-Control": "public, max-age=604800, immutable"},
    )


def _parse_lrc(text: str, duration: float = 0) -> list:
    """LRC text ('[01:23.45] line') to [{text, start, end}] with each line ending where the next begins."""
    import re
    rows = []
    for raw in (text or "").splitlines():
        m = re.match(r"^\s*((?:\[\d+:\d+(?:\.\d+)?\])+)\s*(.*)$", raw)
        if not m:
            continue
        for mm, ss in re.findall(r"\[(\d+):(\d+(?:\.\d+)?)\]", m.group(1)):
            rows.append((int(mm) * 60 + float(ss), m.group(2).strip()))
    rows.sort(key=lambda r: r[0])
    out = []
    for i, (start, line) in enumerate(rows):
        end = rows[i + 1][0] if i + 1 < len(rows) else (duration or start + 5)
        out.append({"text": line, "start": start, "end": end})
    return [l for l in out if l["text"]]


def _lrclib(title: str, artist: str, dur: float):
    """Fallback lyrics from LRCLIB (free, community): synced when it has them, otherwise plain."""
    headers = {"User-Agent": "YTMusic/1 (personal app)"}
    try:
        params = {"track_name": title, "artist_name": artist}
        if dur:
            params["duration"] = str(round(dur))
        r = httpx.get("https://lrclib.net/api/get", params=params, headers=headers, timeout=10)
        j = r.json() if r.status_code == 200 else None

        def good(x):  # community entries can be junk (a one-line test record, say)
            return bool(x) and (len(_parse_lrc(x.get("syncedLyrics") or "")) >= 3 or len(x.get("plainLyrics") or "") >= 40)

        if not good(j):
            r = httpx.get("https://lrclib.net/api/search", params={"q": f"{title} {artist}".strip()}, headers=headers, timeout=10)
            arr = [x for x in (r.json() if r.status_code == 200 else []) if good(x)]

            def near(x):
                return not dur or not x.get("duration") or abs(x["duration"] - dur) <= 6

            j = (next((x for x in arr if x.get("syncedLyrics") and near(x)), None)
                 or next((x for x in arr if x.get("syncedLyrics")), None) or (arr[0] if arr else None))
    except Exception:
        return None
    if not j:
        return None
    if j.get("syncedLyrics"):
        lines = _parse_lrc(j["syncedLyrics"], j.get("duration") or 0)
        if len(lines) >= 3:
            return {"lyrics": "\n".join(l["text"] for l in lines), "lines": lines, "source": "Lyrics from LRCLIB", "hasTimestamps": True}
    if len(j.get("plainLyrics") or "") >= 40:
        return {"lyrics": j["plainLyrics"], "lines": None, "source": "Lyrics from LRCLIB", "hasTimestamps": False}
    return None


@app.get("/api/lyrics/{video_id}", dependencies=[Depends(auth)])
def lyrics(video_id: str, title: str = "", artist: str = "", dur: float = 0):
    pl = _yt().get_watch_playlist(videoId=video_id)
    bid = pl.get("lyrics")
    if bid:
        try:  # time-synced lines when the song has them, so the app can follow along
            timed = _yt().get_lyrics(bid, timestamps=True)
        except Exception:
            timed = None
        if timed and timed.get("hasTimestamps") and isinstance(timed.get("lyrics"), list):
            lines = [
                {"text": l.text, "start": (l.start_time or 0) / 1000, "end": (l.end_time or 0) / 1000}
                for l in timed["lyrics"]
            ]
            return {"lyrics": "\n".join(l["text"] for l in lines), "lines": lines, "source": timed.get("source"), "hasTimestamps": True}
    lr = _lrclib(title, artist, dur) if title else None
    if lr and lr["hasTimestamps"]:
        return lr
    if bid:
        try:
            plain = _yt().get_lyrics(bid)
            if plain.get("lyrics"):
                return {"lyrics": plain["lyrics"], "lines": None, "source": plain.get("source"), "hasTimestamps": False}
        except Exception:
            pass
    if lr:
        return lr
    raise HTTPException(404, "no lyrics")


# ---------------------------------------------------------------- audio
def _resolve(video_id: str, q: str) -> dict:
    key = (video_id, q)
    hit = _stream_cache.get(key)
    if hit and hit["expires"] > time.time() + 60:
        return hit
    opts = {
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "format": FORMATS[q],
        "js_runtimes": {"node": {}},
    }
    with YoutubeDL(opts) as ydl:
        info = ydl.extract_info(f"https://www.youtube.com/watch?v={video_id}", download=False)
    url = info["url"]
    qs = parse_qs(urlparse(url).query)
    expires = float(qs["expire"][0]) if "expire" in qs else time.time() + 3600
    ext = info.get("ext", "m4a")
    entry = {
        "url": url,
        "expires": expires,
        "headers": info.get("http_headers", {}),
        "mime": "audio/mp4" if ext in ("m4a", "mp4") else f"audio/{ext}",
    }
    _stream_cache[key] = entry
    return entry


@app.get("/stream/{video_id}", dependencies=[Depends(auth)])
async def stream(video_id: str, request: Request, q: str = "high"):
    if not re.fullmatch(r"[\w-]{6,20}", video_id):
        raise HTTPException(400, "bad id")
    if q not in FORMATS:
        q = "high"
    try:
        entry = await _run_sync(_resolve, video_id, q)
    except Exception as e:  # yt-dlp raises many types
        log.warning("resolve failed for %s: %s", video_id, e)
        raise HTTPException(502, "could not resolve this song")

    start, end = 0, None
    m = re.fullmatch(r"bytes=(\d*)-(\d*)", request.headers.get("range", ""))
    if m:
        start = int(m.group(1) or 0)
        end = int(m.group(2)) if m.group(2) else None
    cap = start + CHUNK - 1
    end = cap if end is None else min(end, cap)

    headers = dict(entry["headers"])
    headers["Range"] = f"bytes={start}-{end}"
    req = _client.build_request("GET", entry["url"], headers=headers)
    up = await _client.send(req, stream=True)
    if up.status_code not in (200, 206):
        await up.aclose()
        _stream_cache.pop((video_id, q), None)  # likely expired / blocked; re-resolve next time
        raise HTTPException(502, f"upstream {up.status_code}")

    cr = up.headers.get("content-range")  # e.g. bytes 0-4194303/5242880
    out = {
        "Accept-Ranges": "bytes",
        "Content-Type": entry["mime"],
        "Cache-Control": "no-store",
    }
    if cr:
        out["Content-Range"] = cr
        out["Content-Length"] = str(int(up.headers["content-length"]))
        status = 206
    else:  # upstream ignored Range and sent the whole file
        out["Content-Length"] = up.headers.get("content-length", "")
        status = 200

    async def body():
        try:
            async for chunk in up.aiter_raw(64 * 1024):
                yield chunk
        finally:
            await up.aclose()

    return StreamingResponse(body(), status_code=status, headers=out)


# ---------------------------------------------------------------- dev proxy (testing the on-device engine in a browser)
DEV_PROXY = os.environ.get("DEV_PROXY") == "1"
_DEV_HOSTS = ("youtube.com", "googlevideo.com", "googleapis.com", "ytimg.com", "ggpht.com", "gstatic.com", "google.com", "googleusercontent.com")


@app.api_route("/dev/fetch", methods=["GET", "POST"], dependencies=[Depends(auth)])
async def dev_fetch(request: Request, url: str):
    """Forwards one request to YouTube/Google on behalf of a browser, so the on-device engine can be tested without
    the native app (browsers can't set a User-Agent or ignore CORS). Off unless DEV_PROXY=1; token-protected."""
    if not DEV_PROXY:
        raise HTTPException(404, "dev proxy is off")
    import json as _json

    host = (urlparse(url).hostname or "").lower()
    if urlparse(url).scheme != "https" or not any(host == d or host.endswith("." + d) for d in _DEV_HOSTS):
        raise HTTPException(400, "host not allowed")
    fwd = _json.loads(request.headers.get("x-fwd", "{}"))
    method = (fwd.get("method") or "GET").upper()
    drop = {"host", "content-length", "connection", "accept-encoding", "origin-agent-cluster"}
    headers = {k: v for k, v in (fwd.get("headers") or {}).items() if k.lower() not in drop}
    body = await request.body() if method == "POST" else None
    r = await _client.request(method, url, headers=headers, content=body)
    keep = {k: v for k, v in r.headers.items() if k.lower() in ("content-type", "content-range", "accept-ranges")}
    return Response(r.content, status_code=r.status_code, headers=keep)


# ---------------------------------------------------------------- ringtone clips
def _ffmpeg() -> str:
    import shutil

    exe = shutil.which("ffmpeg")
    if exe:
        return exe
    import imageio_ffmpeg  # bundled binary, installed in the venv

    return imageio_ffmpeg.get_ffmpeg_exe()


def _cut(data: bytes, start: float, dur: float) -> Optional[bytes]:
    """Cut [start, start+dur) out of an AAC/MP4 file with a short fade in and out."""
    import subprocess
    import tempfile

    with tempfile.TemporaryDirectory() as d:
        src, dst = Path(d) / "in.m4a", Path(d) / "out.m4a"
        src.write_bytes(data)
        cmd = [
            _ffmpeg(), "-y", "-hide_banner", "-loglevel", "error",
            "-ss", f"{start:.2f}", "-t", f"{dur:.2f}", "-i", str(src), "-vn",
            "-af", f"afade=t=in:d=0.3,afade=t=out:st={max(0.0, dur - 1.5):.2f}:d=1.5",
            "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart", "-f", "ipod", str(dst),
        ]
        flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        r = subprocess.run(cmd, capture_output=True, timeout=90, creationflags=flags)
        if r.returncode != 0 or not dst.exists() or dst.stat().st_size < 4000:
            return None
        return dst.read_bytes()


@app.get("/api/ringtone/{video_id}", dependencies=[Depends(auth)])
async def ringtone(video_id: str, start: float = 0, dur: float = 30):
    """A short AAC clip (default 30 s, max 40 s) of a song, ready for GarageBand / Files."""
    if not re.fullmatch(r"[\w-]{6,20}", video_id):
        raise HTTPException(400, "bad id")
    start, dur = max(0.0, start), max(5.0, min(dur, 40.0))
    try:
        entry = await _run_sync(_resolve, video_id, "high")
    except Exception as e:
        log.warning("resolve failed for %s: %s", video_id, e)
        raise HTTPException(502, "could not resolve this song")
    parts, pos, total = [], 0, None
    while total is None or pos < total:  # the whole file is only ~4 MB; fetch it in ranged chunks
        h = dict(entry["headers"])
        h["Range"] = f"bytes={pos}-{pos + CHUNK - 1}"
        r = await _client.get(entry["url"], headers=h)
        if r.status_code not in (200, 206):
            _stream_cache.pop((video_id, "high"), None)
            raise HTTPException(502, f"upstream {r.status_code}")
        cr = r.headers.get("content-range")
        total = int(cr.split("/")[1]) if cr else len(r.content)
        parts.append(r.content)
        pos += len(r.content)
        if not cr or not r.content:
            break
    out = await _run_sync(_cut, b"".join(parts), start, dur)
    if not out:
        raise HTTPException(400, "could not cut a clip (is the start past the end of the song?)")
    return Response(
        out, media_type="audio/mp4",
        headers={"Content-Disposition": 'attachment; filename="ringtone.m4a"', "Cache-Control": "no-store"},
    )


async def _run_sync(fn, *a):
    from starlette.concurrency import run_in_threadpool

    return await run_in_threadpool(fn, *a)


@app.get("/health")
def health():
    return {"ok": True}


class NoCacheStatic(StaticFiles):
    """Always revalidate app files, so phones pick up updates instead of reusing heuristically cached copies."""

    async def get_response(self, path, scope):
        r = await super().get_response(path, scope)
        r.headers["Cache-Control"] = "no-cache"
        return r


# Over-the-air install of the native app: /ota/ has the install page, manifest.plist and the .ipa (see ios-app/scripts/make_ota.py)
OTA_DIR = Path(__file__).resolve().parent / "ota"
OTA_DIR.mkdir(exist_ok=True)
mimetypes.add_type("application/octet-stream", ".ipa")
mimetypes.add_type("text/xml", ".plist")
app.mount("/ota", NoCacheStatic(directory=OTA_DIR, html=True), name="ota")

if FRONTEND.exists():
    app.mount("/", NoCacheStatic(directory=FRONTEND, html=True), name="frontend")
