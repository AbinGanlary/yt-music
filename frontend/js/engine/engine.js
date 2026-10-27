// On-device music engine: the same endpoints the Python backend offers, answered straight from YouTube Music.
// It knows nothing about where it runs: the caller injects the InnerTube client (youtubei.js) and a `fetch`
// (native HTTP in the app, the dev proxy in a browser, plain fetch in Node tests).
//
//   const engine = createEngine({ Innertube, fetch });
//   await engine.handle("/api/search?q=yellow&filter=songs");   // → same JSON the server returns
//   await engine.resolveStream("9qnqYL0eNNI", "high");          // → { url, expires, mime, bitrate }
import { COUNTRIES } from "./countries.js";

const T = (x) => (typeof x === "string" ? x : x?.text ?? "");
const last = (a) => (Array.isArray(a) && a.length ? a[a.length - 1]?.url ?? null : null);
const dedupe = (arr, key) => { const seen = new Set(); return arr.filter((x) => x && !seen.has(x[key]) && seen.add(x[key])); };
const rawText = (o) => o?.runs?.map((r) => r.text).join("") ?? o?.simpleText ?? "";
const stripVL = (id) => (id && id.startsWith("VL") ? id.slice(2) : id);

/** Every value stored under `key`, anywhere in a raw JSON tree. */
function collect(node, key, out = []) {
  if (node && typeof node === "object") {
    if (Array.isArray(node)) { for (const x of node) collect(x, key, out); }
    else for (const [k, v] of Object.entries(node)) { if (k === key) out.push(v); else collect(v, key, out); }
  }
  return out;
}

export function createEngine({ Innertube, fetch: doFetch, probe = null, auth = null, now = () => Date.now() }) {
  // auth: { get(): credentials | null, set(credentials | null) }. Optional Google sign-in (the TV "device code" flow),
  // used for the account's own pages and as an extra way to get audio when YouTube asks anonymous clients to sign in.
  const authStore = auth || { get: () => null, set: () => {} };
  const notSignedIn = () => Object.assign(new Error("not signed in"), { status: 401 });

  /* ---------- sessions (one per country, created lazily) ---------- */
  const sessions = new Map(), signedSessions = new Map();
  const cleanLoc = (loc) => { const key = String(loc || "").toUpperCase(); return key && !COUNTRIES.includes(key) ? "" : key; };
  const getYT = (loc) => {
    const key = cleanLoc(loc);
    if (!sessions.has(key)) {
      const p = Innertube.create({ fetch: doFetch, location: key || undefined, lang: "en", retrieve_player: false })
        .catch((e) => { sessions.delete(key); throw e; });
      sessions.set(key, p);
    }
    return sessions.get(key);
  };
  /** A session carrying the signed-in account's tokens (refreshed tokens are saved back through authStore). */
  const getSignedYT = (loc) => {
    const creds = authStore.get();
    if (!creds) return Promise.reject(notSignedIn());
    const key = cleanLoc(loc);
    if (!signedSessions.has(key)) {
      const p = (async () => {
        const yt = await Innertube.create({ fetch: doFetch, location: key || undefined, lang: "en", retrieve_player: false });
        yt.session.on("update-credentials", ({ credentials }) => authStore.set(credentials));
        await yt.session.signIn(creds);
        return yt;
      })().catch((e) => { signedSessions.delete(key); throw e; });
      signedSessions.set(key, p);
    }
    return signedSessions.get(key);
  };

  /* ---------- small TTL cache ---------- */
  const cache = new Map();
  async function cached(key, ttlMs, fn) {
    const hit = cache.get(key);
    if (hit && hit.exp > now()) return hit.val;
    const val = await fn();
    cache.set(key, { exp: now() + ttlMs, val });
    return val;
  }

  /* ---------- shaping (mirrors backend/main.py) ---------- */
  const coll = (kind, id, title, subtitle, thumbnail) => ({ kind, id, title, subtitle: subtitle || "", thumbnail: thumbnail || null });

  /** A song or video from a search / playlist / album row (MusicResponsiveListItem). */
  function trackFromList(it, fb = {}) {
    const id = it?.id || it?.video_id || it?.endpoint?.payload?.videoId;
    if (!id) return null;
    let artists = (it.artists || []).map((a) => a.name).filter(Boolean);
    let artistIds = (it.artists || []).map((a) => a.channel_id).filter(Boolean);
    if (!artists.length) {                                   // videos: "Artist, Artist • 10M views"
      const col = it.flex_columns?.[1]?.title;
      const runs = col?.runs || [];
      const linked = runs.filter((r) => String(r.endpoint?.payload?.browseId || "").startsWith("UC"));
      if (linked.length) { artists = linked.map((r) => r.text); artistIds = linked.map((r) => r.endpoint.payload.browseId); }
      else {
        const first = T(col).split(" • ")[0];
        const author = T(it.author?.name ?? it.author);
        artists = (author ? [author] : first && !/views?$/i.test(first) ? first.split(/,\s*|\s+&\s+/) : []).filter(Boolean);
      }
    }
    if (!artists.length && fb.artists) { artists = fb.artists; artistIds = fb.artistIds || []; }
    return {
      videoId: id,
      title: T(it.title) || T(it.flex_columns?.[0]?.title),
      artists, artistIds,
      album: it.album?.name ?? fb.album ?? null,
      albumId: it.album?.id ?? fb.albumId ?? null,
      duration: it.duration?.text ?? null,
      thumbnail: last(it.thumbnails) ?? last(it.thumbnail?.contents) ?? fb.thumbnail ?? null,
      ...(it.item_type === "video" ? { video: true } : {}),
    };
  }
  /** A row from the up-next / radio panel (PlaylistPanelVideo). */
  function trackFromPanel(v) {
    if (!v?.video_id) return null;
    return {
      videoId: v.video_id, title: T(v.title),
      artists: (v.artists || []).map((a) => a.name).filter(Boolean),
      artistIds: (v.artists || []).map((a) => a.channel_id).filter(Boolean),
      album: v.album?.name ?? null, albumId: v.album?.id ?? null,
      duration: v.duration?.text ?? null, thumbnail: last(v.thumbnail),
      ...(/_(OMV|UGC)$/.test(v.endpoint?.payload?.watchEndpointMusicSupportedConfigs?.watchEndpointMusicConfig?.musicVideoType || "") ? { video: true } : {}),
    };
  }
  const cleanSubtitle = (s) => (s || "").split(" • ").filter((p, i) => !(i === 0 && /^(single|album|ep|playlist|song|video|artist)$/i.test(p))).join(", ");
  const collFromTwoRow = (it, kind) => {
    const k = kind || it.item_type || "album";
    const id = it.id || it.endpoint?.payload?.browseId;
    if (!id) return null;
    return coll(k, k === "playlist" ? stripVL(id) : id, T(it.title), cleanSubtitle(T(it.subtitle)), last(it.thumbnail));
  };
  async function rawBrowse(yt, body) {
    const r = await yt.actions.execute("/browse", { ...body, client: "YTMUSIC", parse: false });
    return r.data;
  }
  // first page: shelves of rows; later pages (SearchContinuation): one shelf object holding the rows
  const flatSearch = (res) => (Array.isArray(res.contents) ? res.contents.flatMap((sh) => sh.contents || []) : res.contents?.contents || []);

  /* ---------- handlers ---------- */
  const H = {};

  H.search = async ({ q, filter = "songs", limit = 40, loc }) => {
    const yt = await getYT(loc);
    let res = await yt.music.search(q, { type: filter === "videos" ? "video" : "song" });
    let items = flatSearch(res);
    for (let i = 0; i < 2 && items.length < limit && res.has_continuation; i++) {
      try { res = await res.getContinuation(); items = items.concat(flatSearch(res)); } catch { break; }
    }
    return dedupe(items.map((it) => (["song", "video"].includes(it.item_type) ? trackFromList(it) : null)).filter(Boolean), "videoId").slice(0, limit);
  };

  /** A genre / mood / style by name: its songs and playlists, found with two searches (for the Mix tab). */
  H.genre = async ({ q, loc }) => cached(`genre:${q.toLowerCase()}:${loc}`, 20 * 60e3, async () => {
    const yt = await getYT(loc);
    const [songs, found] = await Promise.all([
      H.search({ q, filter: "songs", limit: 25, loc }).catch(() => []),
      yt.music.search(q, { type: "playlist" }).then(flatSearch).catch(() => []),
    ]);
    const playlists = dedupe(found.filter((i) => i.item_type === "playlist" && i.id)
      .map((i) => coll("playlist", stripVL(i.id), T(i.title), T(i.author?.name ?? i.author), last(i.thumbnails))), "id").slice(0, 16);
    return { songs, playlists };
  });

  /**
   * The "song" version of a music video, as YouTube Music itself plays it: the album art and clean title instead of the
   * video's thumbnail. Found by searching songs and matching the title, an artist and the length. null when none matches.
   */
  H.counterpart = async ({ id, title = "", artist = "", dur = "", loc }) => cached(`cp:${id}`, 24 * 3600e3, async () => {
    const clean = (x) => String(x).replace(/[\(\[][^\)\]]*(official|video|audio|lyric|visuali[sz]er|music video|hd|4k)[^\)\]]*[\)\]]/gi, " ").replace(/\s*[|\-–]\s*(official.*|lyric.*|video.*)$/i, "").replace(/\s+/g, " ").trim();
    const norm = (x) => clean(x).toLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim();
    const secs = (d) => { const m = /^(?:(\d+):)?(\d+):(\d{2})$/.exec(String(d || "")); return m ? Number(m[1] || 0) * 3600 + Number(m[2]) * 60 + Number(m[3]) : Number(d) || 0; };
    const want = norm(title), wa = norm(String(artist).split(",")[0]), wd = secs(dur);
    if (!want) return null;
    const found = await H.search({ q: `${clean(title)} ${String(artist).split(",")[0]}`.trim(), filter: "songs", limit: 6, loc });
    let best = null, top = 0;
    for (const t of found) {
      const nt = norm(t.title);
      const score = (nt === want ? 3 : nt && (nt.includes(want) || want.includes(nt)) ? 1 : 0)
        + (t.artists.some((a) => { const na = norm(a); return na && wa && (na.includes(wa) || wa.includes(na)); }) ? 2 : 0)
        + (wd && t.duration && Math.abs(secs(t.duration) - wd) <= 6 ? 2 : 0);
      if (score > top) { top = score; best = t; }
    }
    return top >= 4 ? best : null;
  });

  H.suggest = async ({ q, loc }) => {
    const yt = await getYT(loc);
    const s = await yt.music.getSearchSuggestions(q);
    return s.flatMap((sec) => (sec.contents || []).map((c) => T(c.suggestion))).filter(Boolean).slice(0, 8);
  };

  H.radio = async ({ id, limit = 25, loc }) => {
    const yt = await getYT(loc);
    let panel = await yt.music.getUpNext(id);
    let list = dedupe((panel.contents || []).map(trackFromPanel).filter(Boolean), "videoId");
    if (list[0]?.video && list[0].videoId === id) {        // started from a music video: radio from its song version instead, so the queue is songs
      const c = await H.counterpart({ id, title: list[0].title, artist: list[0].artists.join(", "), dur: list[0].duration, loc }).catch(() => null);
      if (c) { try { panel = await yt.music.getUpNext(c.videoId); list = dedupe((panel.contents || []).map(trackFromPanel).filter(Boolean), "videoId"); } catch { /* keep the video radio */ } }
    }
    return await songify(list.slice(0, Math.max(limit, 50)), loc);
  };

  /** Swap music videos in a list for their YouTube Music song versions (album art, clean titles); five lookups at a time. */
  async function songify(tracks, loc) {
    const out = new Array(tracks.length);
    let i = 0;
    const worker = async () => {
      while (i < tracks.length) {
        const k = i++, t = tracks[k];
        if (!t.video) { out[k] = t; continue; }
        const c = await H.counterpart({ id: t.videoId, title: t.title, artist: t.artists.join(", "), dur: t.duration, loc }).catch(() => null);
        out[k] = c ? { ...c, swapped: true } : t;
      }
    };
    await Promise.all([worker(), worker(), worker(), worker(), worker()]);
    return dedupe(out, "videoId");
  }
  /** Songs only, when enough of them are left (a video with no song version is dropped from these shelves). */
  const songsOnly = (list) => { const s = list.filter((t) => !t.video); return s.length >= 8 ? s : list; };

  /** "Quick picks": the Explore page's Trending list (songs and videos with ids). */
  H.home = async ({ loc }) => cached(`home:${loc}`, 30 * 60e3, async () => {
    if (!loc) {                                              // Global content: the worldwide chart, as songs
      const top = await H.trending({ country: "ZZ", loc }).catch(() => []);
      if (top.length >= 8) return [{ title: "Quick picks", items: top.slice(0, 20) }];
    }
    const yt = await getYT(loc);
    const ex = await yt.music.getExplore();
    const pick = (title) => (ex.sections || []).find((s) => T(s.header?.title) === title);
    const items = [...(pick("Trending")?.contents || []), ...(pick("New music videos")?.contents || [])]
      .map((it) => trackFromList(it)).filter(Boolean);
    const tracks = songsOnly(await songify(dedupe(items, "videoId").slice(0, 24), loc)).slice(0, 20);
    return tracks.length ? [{ title: "Quick picks", items: tracks }] : [];
  });

  H.countries = async () => COUNTRIES.slice();

  async function chartsRaw(country, loc) {
    return cached(`chartsraw:${country}:${loc}`, 30 * 60e3, async () => {
      const yt = await getYT(loc || (country !== "ZZ" ? country : ""));
      const body = { browseId: "FEmusic_charts" };
      body.formData = { selectedValues: [country || "ZZ"] };
      return rawBrowse(yt, body);
    });
  }
  H.charts = async ({ country = "ZZ", loc }) => {
    const data = await chartsRaw(country, loc);
    const shelves = collect(data, "musicCarouselShelfRenderer");
    const titleOf = (s) => rawText(s.header?.musicCarouselShelfBasicHeaderRenderer?.title);
    const videoShelf = shelves.find((s) => /video charts/i.test(titleOf(s))) || shelves.find((s) => collect(s, "musicTwoRowItemRenderer").length);
    const playlists = collect(videoShelf, "musicTwoRowItemRenderer").map((x) => {
      const id = x.navigationEndpoint?.browseEndpoint?.browseId;
      return id ? coll("playlist", stripVL(id), rawText(x.title), "Chart", last(x.thumbnailRenderer?.musicThumbnailRenderer?.thumbnail?.thumbnails)) : null;
    }).filter(Boolean);
    const artistShelf = shelves.find((s) => /top artists/i.test(titleOf(s)));
    const artists = collect(artistShelf, "musicResponsiveListItemRenderer").map((x) => {
      const id = x.navigationEndpoint?.browseEndpoint?.browseId;
      const cols = x.flexColumns || [];
      const col = (i) => rawText(cols[i]?.musicResponsiveListItemFlexColumnRenderer?.text);
      return id?.startsWith("UC") ? coll("artist", id, col(0), col(1).replace(/\s*subscribers?$/i, ""), last(x.thumbnail?.musicThumbnailRenderer?.thumbnail?.thumbnails)) : null;
    }).filter(Boolean);
    return { playlists, artists };
  };

  H.trending = async ({ country = "IN", loc }) => cached(`trending:${country}`, 30 * 60e3, async () => {
    const { playlists } = await H.charts({ country, loc });
    for (const p of playlists.slice(0, 2)) {
      try { const pg = await H.playlist({ id: p.id, loc }); if (pg.tracks.length) return songsOnly(await songify(pg.tracks.slice(0, 30), loc)).slice(0, 25); } catch {}
    }
    return [];
  });

  H.explore = async ({ loc }) => cached(`explore:${loc}`, 30 * 60e3, async () => {
    const yt = await getYT(loc);
    const [ex, moodData] = await Promise.all([yt.music.getExplore(), rawBrowse(yt, { browseId: "FEmusic_moods_and_genres" })]);
    const rel = (ex.sections || []).find((s) => /^New albums/i.test(T(s.header?.title)));
    const newReleases = (rel?.contents || []).map((it) => collFromTwoRow(it, "album")).filter(Boolean);
    const moods = collect(moodData, "gridRenderer").map((g) => ({
      section: rawText(g.header?.gridHeaderRenderer?.title),
      items: (g.items || []).map((i) => i.musicNavigationButtonRenderer).filter(Boolean).map((b) => ({
        title: rawText(b.buttonText), params: b.clickCommand?.browseEndpoint?.params,
      })).filter((m) => m.title && m.params),
    })).filter((s) => s.section && s.items.length);
    return { newReleases, moods };
  });

  H.mood = async ({ params, loc }) => cached(`mood:${params}:${loc}`, 30 * 60e3, async () => {
    const yt = await getYT(loc);
    const data = await rawBrowse(yt, { browseId: "FEmusic_moods_and_genres_category", params });
    const out = [];
    for (const x of collect(data, "musicTwoRowItemRenderer")) {
      const id = x.navigationEndpoint?.browseEndpoint?.browseId;
      if (id?.startsWith("VL")) out.push(coll("playlist", stripVL(id), rawText(x.title), "", last(x.thumbnailRenderer?.musicThumbnailRenderer?.thumbnail?.thumbnails)));
      if (out.length >= 40) break;
    }
    return out;
  });

  H.album = async ({ id, loc }) => {
    const yt = await getYT(loc);
    const a = await yt.music.getAlbum(id);
    const h = a.header, thumb = last(h?.thumbnail?.contents);
    const runs = h?.strapline_text_one?.runs || [];
    const artistRuns = runs.filter((r) => String(r.endpoint?.payload?.browseId || "").startsWith("UC"));
    const artists = (artistRuns.length ? artistRuns.map((r) => r.text) : [T(h?.strapline_text_one)]).filter(Boolean);
    const artistIds = artistRuns.map((r) => r.endpoint.payload.browseId);
    const year = (h?.subtitle?.runs || []).map((r) => r.text).find((t) => /^\d{4}$/.test(t));
    const title = T(h?.title);
    return {
      kind: "album", title, thumbnail: thumb, subtitle: artists.join(", "),
      meta: [year, ...T(h?.second_subtitle).split(" • ")].filter(Boolean).join(" · "),
      tracks: (a.contents || []).map((it) => trackFromList(it, { artists, artistIds, album: title, albumId: id, thumbnail: thumb })).filter(Boolean),
    };
  };

  H.playlist = async ({ id, loc }) => cached(`pl:${id}:${loc}`, 15 * 60e3, async () => {
    const yt = await getYT(loc);
    const p = await yt.music.getPlaylist(id);
    const h = p.header, thumb = last(h?.thumbnail?.contents);
    return {
      kind: "playlist", title: T(h?.title), thumbnail: thumb,
      subtitle: T(h?.strapline_text_one), meta: T(h?.second_subtitle).split(" • ")[0] || "",
      tracks: (p.contents || []).map((it) => trackFromList(it, { thumbnail: thumb })).filter(Boolean),
    };
  });

  H.artist = async ({ id, loc }) => {
    const yt = await getYT(loc);
    const a = await yt.music.getArtist(id);
    const h = a.header, name = T(h?.title), thumb = last(h?.thumbnail?.contents);
    const sec = (re) => (a.sections || []).find((s) => re.test(T(s.header?.title ?? s.title)));
    const songs = (sec(/top songs/i)?.contents || []).map((it) => trackFromList(it, { artists: [name], artistIds: [id], thumbnail: thumb })).filter(Boolean);
    const albums = (sec(/^albums$/i)?.contents || []).map((it) => collFromTwoRow(it, "album")).filter(Boolean);
    return { kind: "artist", title: name, thumbnail: thumb, subtitle: "", meta: "", tracks: songs, albums, radioVideoId: songs[0]?.videoId ?? null };
  };

  H.artistsSearch = async ({ q, loc }) => {
    const yt = await getYT(loc);
    const res = await yt.music.search(q, { type: "artist" });
    return flatSearch(res).filter((it) => it.item_type === "artist" && it.id).slice(0, 15)
      .map((it) => coll("artist", it.id, T(it.name), "", last(it.thumbnails)));
  };

  /** Songs from the user's picked artists and languages, interleaved. */
  H.mix = async ({ artists = "", langs = "", loc }) => {
    const aids = artists.split(",").filter(Boolean).slice(0, 6), lgs = langs.split(",").filter(Boolean).slice(0, 3);
    return cached(`mix:${aids.sort()}:${lgs.sort()}:${loc}`, 20 * 60e3, async () => {
      const jobs = [
        ...aids.map(async (id) => {
          const pg = await H.artist({ id, loc });
          let out = pg.tracks.slice();
          if (pg.radioVideoId) { try { out = out.concat((await H.radio({ id: pg.radioVideoId, limit: 15, loc })).slice(0, 15)); } catch {} }
          return out;
        }),
        ...lgs.map((l) => H.search({ q: `new ${l} songs`, filter: "songs", limit: 20, loc })),
      ];
      const lists = (await Promise.allSettled(jobs)).filter((r) => r.status === "fulfilled").map((r) => r.value);
      const seen = new Set(), out = [];
      for (let i = 0; i < Math.max(0, ...lists.map((l) => l.length)); i++) {
        for (const l of lists) if (i < l.length && !seen.has(l[i].videoId)) { seen.add(l[i].videoId); out.push(l[i]); }
      }
      const head = out.slice(0, 6), tail = out.slice(6);
      for (let i = tail.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [tail[i], tail[j]] = [tail[j], tail[i]]; }
      return head.concat(tail).slice(0, 40);
    });
  };

  /** Lyrics: time-synced when the song has them (the Android Music client exposes the timings), otherwise plain text. */
  /** "[01:23.45] line" text to [{text, start, end}], each line ending where the next begins. */
  const parseLrc = (text, duration = 0) => {
    const rows = [];
    for (const raw of String(text || "").split(/\r?\n/)) {
      const m = /^\s*((?:\[\d+:\d+(?:\.\d+)?\])+)\s*(.*)$/.exec(raw);
      if (!m) continue;
      for (const t of m[1].matchAll(/\[(\d+):(\d+(?:\.\d+)?)\]/g)) rows.push([Number(t[1]) * 60 + Number(t[2]), m[2].trim()]);
    }
    rows.sort((a, b) => a[0] - b[0]);
    return rows.map(([start, line], i) => ({ text: line, start, end: i + 1 < rows.length ? rows[i + 1][0] : duration || start + 5 })).filter((l) => l.text);
  };
  /** Fallback lyrics from LRCLIB (free, community): synced when it has them, otherwise plain. */
  async function lrclib({ title, artist, dur }) {
    if (!title) return null;
    try {
      const get = async (url) => { const r = await doFetch(url, { headers: { "user-agent": "YTMusic/1 (personal app)" } }); return r.ok ? r.json() : null; };
      const q = new URLSearchParams({ track_name: title, artist_name: artist || "" });
      if (dur) q.set("duration", String(Math.round(dur)));
      // community entries can be junk (a one-line test record, say), so only accept real-looking lyrics
      const good = (x) => x && ((x.syncedLyrics && parseLrc(x.syncedLyrics).length >= 3) || (x.plainLyrics || "").length >= 40);
      let j = await get(`https://lrclib.net/api/get?${q}`);
      if (!good(j)) {
        const arr = ((await get(`https://lrclib.net/api/search?q=${encodeURIComponent(`${title} ${artist || ""}`.trim())}`)) || []).filter(good);
        const near = (x) => !dur || !x.duration || Math.abs(x.duration - dur) <= 6;
        j = arr.find((x) => x.syncedLyrics && near(x)) || arr.find((x) => x.syncedLyrics) || arr[0] || null;
      }
      if (!j) return null;
      if (j.syncedLyrics) {
        const lines = parseLrc(j.syncedLyrics, j.duration || 0);
        if (lines.length >= 3) return { lyrics: lines.map((l) => l.text).join("\n"), lines, source: "Lyrics from LRCLIB", hasTimestamps: true };
      }
      if ((j.plainLyrics || "").length >= 40) return { lyrics: j.plainLyrics, lines: null, source: "Lyrics from LRCLIB", hasTimestamps: false };
    } catch { /* offline or blocked: no fallback */ }
    return null;
  }

  H.lyrics = async ({ id, loc, title = "", artist = "", dur = 0 }) => {
    const yt = await getYT(loc);
    try {
      const next = (await yt.actions.execute("/next", { videoId: id, client: "YTMUSIC", parse: false })).data;
      const tab = collect(next, "tabRenderer").find((t) =>
        t.endpoint?.browseEndpoint?.browseEndpointContextSupportedConfigs?.browseEndpointContextMusicConfig?.pageType === "MUSIC_PAGE_TYPE_TRACK_LYRICS");
      const browseId = tab?.endpoint?.browseEndpoint?.browseId;
      if (browseId) {
        // the timings only come from the Android Music client; the library's own config for it is rejected, so send the request directly
        const res = await doFetch("https://music.youtube.com/youtubei/v1/browse?alt=json", {
          method: "POST",
          headers: { "content-type": "application/json", origin: "https://music.youtube.com", "user-agent": "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/130.0 Mobile Safari/537.36" },
          body: JSON.stringify({ context: { client: { clientName: "ANDROID_MUSIC", clientVersion: "7.21.50", hl: "en", gl: (loc || "US").toUpperCase() }, user: {} }, browseId }),
        });
        const page = await res.json();
        const data = collect(page, "timedLyricsModel")[0]?.lyricsData;
        const raw = data?.timedLyricsData;
        if (raw?.length && raw.every((l) => l.cueRange)) {
          const lines = raw.map((l) => ({ text: l.lyricLine, start: Number(l.cueRange.startTimeMilliseconds) / 1000, end: Number(l.cueRange.endTimeMilliseconds) / 1000 }));
          return { lyrics: lines.map((l) => l.text).join("\n"), lines, source: data.sourceMessage || null, hasTimestamps: true };
        }
      }
    } catch { /* fall back to LRCLIB, then to plain lyrics */ }
    const lr = await lrclib({ title, artist, dur });
    if (lr?.hasTimestamps) return lr;                          // synced lines beat plain text
    let text = "", footer = null;
    try { const l = await yt.music.getLyrics(id); text = T(l?.description); footer = T(l?.footer) || null; } catch { /* none */ }
    if (text) return { lyrics: text, lines: null, source: footer, hasTimestamps: false };
    if (lr) return lr;
    const e = new Error("no lyrics"); e.status = 404; throw e;
  };

  /* ---------- the signed-in account (all of these need Settings → Account → Sign in) ---------- */
  H.account = async () => {
    if (!authStore.get()) return { signedIn: false };
    try {
      const info = await (await getSignedYT("")).account.getInfo(), c = info.contents;
      return { signedIn: true, name: T(c?.account_name), handle: T(c?.channel_handle), photo: c?.account_photo?.[0]?.url || null };
    } catch (e) { return { signedIn: true, error: String(e?.message || e).slice(0, 140) }; }
  };

  /** YouTube Music's own, personalised Home: shelves of songs or of albums / playlists. */
  H.ytHome = async () => cached("ythome", 10 * 60e3, async () => {
    const feed = await (await getSignedYT("")).music.getHomeFeed(), out = [];
    for (const s of feed.sections || []) {
      const title = T(s.header?.title), items = s.contents || [];
      const tracks = items.filter((it) => it.type === "MusicResponsiveListItem" && ["song", "video"].includes(it.item_type)).map((it) => trackFromList(it)).filter(Boolean);
      if (tracks.length >= 3) { out.push({ title, kind: "tracks", items: tracks }); continue; }
      const colls = items.filter((it) => it.type === "MusicTwoRowItem").map((it) => collFromTwoRow(it)).filter(Boolean);
      if (colls.length >= 2) out.push({ title, kind: "colls", items: colls });
    }
    return out;
  });

  /** The account's liked songs ("Liked music" on YouTube Music), shaped like a playlist page. */
  H.liked = async () => cached("liked", 5 * 60e3, async () => {
    const p = await (await getSignedYT("")).music.getPlaylist("LM");
    const thumb = last(p.header?.thumbnail?.contents);
    return { kind: "playlist", title: "Liked music", thumbnail: thumb, subtitle: "YouTube Music", meta: "", tracks: (p.contents || []).map((it) => trackFromList(it, { thumbnail: thumb })).filter(Boolean) };
  });

  /** Starts Google's device sign-in: resolves with the code to type at google.com/device, and `done` settles when approved. */
  async function startSignIn() {
    const yt = await Innertube.create({ fetch: doFetch, lang: "en", retrieve_player: false });
    return new Promise((resolve, reject) => {
      const done = new Promise((ok, no) => {
        yt.session.on("auth", ({ credentials }) => { authStore.set(credentials); signedSessions.clear(); cache.delete("ythome"); cache.delete("liked"); ok(); });
        yt.session.on("auth-error", (e) => no(e));
      });
      done.catch(() => {});                                  // the caller handles it; avoid an unhandled rejection if nobody does
      yt.session.on("auth-pending", (d) => resolve({ url: d.verification_url, code: d.user_code, expiresIn: d.expires_in, done }));
      yt.session.signIn().catch(reject);
    });
  }
  async function signOut() {
    const creds = authStore.get();
    authStore.set(null); signedSessions.clear(); cache.delete("ythome"); cache.delete("liked");
    if (creds?.access_token) { try { await doFetch(`https://www.youtube.com/o/oauth2/revoke?token=${encodeURIComponent(creds.access_token)}`, { method: "POST" }); } catch { /* the tokens are gone locally either way */ } }
  }

  /* ---------- the router: same paths as the server ---------- */
  async function handle(path) {
    const u = new URL(path, "http://engine.local");
    const p = u.searchParams, seg = u.pathname.split("/").filter(Boolean);   // ["api", "search"]
    const loc = p.get("loc") || "";
    if (seg[0] !== "api") throw Object.assign(new Error("unsupported path " + u.pathname), { status: 404 });
    const [, name, arg] = seg;
    switch (name) {
      case "search": return H.search({ q: p.get("q") || "", filter: p.get("filter") || "songs", limit: Number(p.get("limit")) || 40, loc });
      case "suggest": return H.suggest({ q: p.get("q") || "", loc });
      case "genre": return H.genre({ q: p.get("q") || "", loc });
      case "counterpart": return H.counterpart({ id: arg, title: p.get("title") || "", artist: p.get("artist") || "", dur: p.get("dur") || "", loc });
      case "radio": return H.radio({ id: arg, limit: Number(p.get("limit")) || 25, loc });
      case "home": return H.home({ loc });
      case "trending": return H.trending({ country: p.get("country") || "IN", loc });
      case "explore": return H.explore({ loc });
      case "charts": return H.charts({ country: p.get("country") || "ZZ", loc });
      case "mood": return H.mood({ params: p.get("params") || "", loc });
      case "album": return H.album({ id: arg, loc });
      case "playlist": return H.playlist({ id: arg, loc });
      case "artist": return H.artist({ id: arg, loc });
      case "artists": if (arg === "search") return H.artistsSearch({ q: p.get("q") || "", loc }); break;
      case "mix": return H.mix({ artists: p.get("artists") || "", langs: p.get("langs") || "", loc });
      case "countries": return H.countries();
      case "account": return H.account();
      case "ythome": return H.ytHome();
      case "liked": return H.liked();
      case "lyrics": return H.lyrics({ id: arg, loc, title: p.get("title") || "", artist: p.get("artist") || "", dur: Number(p.get("dur")) || 0 });
    }
    throw Object.assign(new Error("unsupported endpoint " + u.pathname), { status: 404 });
  }

  /* ---------- audio: a direct, phone-bound stream address ---------- */
  const streams = new Map();
  const aacFormats = (info) => (info.streaming_data?.adaptive_formats || [])
    .filter((f) => f.has_audio && !f.has_video && /audio\/mp4/.test(f.mime_type || "") && f.bitrate)
    .sort((a, b) => a.bitrate - b.bitrate);
  // VISIONOS returns full-length plain addresses with no signature or token (checked: any range, open-ended, seeks).
  // IOS and ANDROID_VR also return plain addresses but only serve the first ~1 MiB (about a minute) without a
  // proof-of-origin token, so they are a degraded last resort.
  // Each address is checked with a tiny range request before it is handed out: googlevideo sometimes answers 403 for a
  // fresh address (it is tied to the session and network it was issued to). When VISIONOS is refused, it is retried
  // once with a brand-new session before falling back to the degraded clients. fresh >= 2 also starts a new session.
  // (Signed-in tokens are not tried here: YouTube answers HTTP 400 when the TV sign-in tokens are used with these clients.)
  const ATTEMPTS = [["VISIONOS", "anon"], ["VISIONOS", "renew"], ["IOS", "anon"], ["ANDROID_VR", "anon"]];
  async function resolveStream(id, quality = "high", fresh = false) {
    const key = `${id}:${quality}`, hit = streams.get(key);
    if (!fresh && hit && hit.expires > now() + 60e3) return hit;
    streams.delete(key);
    if (fresh >= 2) sessions.delete("");
    let lastErr = null, refused = false;
    const errs = [];
    for (const [client, mode] of ATTEMPTS) {
      if (mode === "renew" && !refused) continue;            // only retry with a new session when the first address was refused
      if (mode === "auth" && !authStore.get()) continue;
      const renew = mode === "renew";
      try {
        if (renew) sessions.delete("");
        const yt = mode === "auth" ? await getSignedYT("") : await getYT("");
        const info = await yt.getBasicInfo(id, { client });
        const status = info.playability_status?.status;
        const tag = mode === "auth" ? `${client} (signed in)` : client;
        if (status && status !== "OK") { lastErr = new Error(`${tag}: ${status} ${String(info.playability_status?.reason || "").slice(0, 50)}`); errs.push(lastErr.message); continue; }
        const fmts = aacFormats(info);
        if (!fmts.length) { lastErr = new Error(`${tag}: no AAC audio formats`); errs.push(lastErr.message); continue; }
        const pick = quality === "low" ? fmts[0] : fmts[fmts.length - 1];
        const url = pick.url || (await pick.decipher?.(yt.session.player));
        if (!url) { lastErr = new Error(`${tag}: no direct url`); errs.push(lastErr.message); continue; }
        const q = new URL(url).searchParams, exp = Number(q.get("expire"));
        if (probe) {
          const st = await probe(url);
          if (st !== 200 && st !== 206) {
            refused = true;
            const ip = String(q.get("ip") || "").slice(0, 24);
            lastErr = new Error(`${tag}${renew ? " (new session)" : ""}: audio ${st}${ip ? ", address for " + ip : ""}`);
            errs.push(lastErr.message); continue;
          }
        }
        const out = { url, expires: exp ? exp * 1000 : now() + 3600e3, mime: "audio/mp4", itag: pick.itag, bitrate: pick.bitrate, approxMs: Number(pick.approx_duration_ms) || 0, size: Number(pick.content_length) || 0, client, signed: mode === "auth", degraded: client !== "VISIONOS" };
        streams.set(key, out);
        return out;
      } catch (e) { lastErr = e; errs.push(String(e.message || e).slice(0, 80)); }
    }
    throw errs.length > 1 ? new Error(errs.join(" | ")) : lastErr || new Error("could not resolve audio");
  }

  /** For the Connection check: what each client returns for one song, and whether its address serves the start and a spot 3 MB in. */
  async function probeClients(id) {
    const out = [];
    const rows = ["VISIONOS", "IOS", "ANDROID_VR"].map((c) => [c, false]);
    for (const [client, signed] of rows) {
      const label = signed ? `${client} (signed in)` : client;
      try {
        const yt = signed ? await getSignedYT("") : await getYT("");
        const info = await yt.getBasicInfo(id, { client });
        const st = info.playability_status?.status;
        if (st && st !== "OK") { out.push(`${label}: ${st} (${String(info.playability_status?.reason || "").slice(0, 60)})`); continue; }
        const fmts = aacFormats(info);
        if (!fmts.length) { out.push(`${label}: no AAC formats`); continue; }
        const pick = fmts[fmts.length - 1], url = pick.url || (await pick.decipher?.(yt.session.player));
        if (!url) { out.push(`${label}: no direct address`); continue; }
        out.push(`${label}: start ${probe ? await probe(url, 0, 1) : "?"}, 3 MB in ${probe ? await probe(url, 3000000, 3000001) : "?"}`);
      } catch (e) { out.push(`${label}: ${String(e?.message || e).replace(/https?:\/\/\S+/g, "").slice(0, 90)}`); }
    }
    return out;
  }

  /** What YouTube thinks this session is (for the Connection check): the address it sees and the start of the visitor id. */
  async function sessionInfo() {
    const c = (await getYT("")).session.context.client;
    return { remoteHost: c.remoteHost || "?", visitor: String(c.visitorData || "").slice(0, 10) };
  }

  return { handle, resolveStream, probeClients, sessionInfo, startSignIn, signOut, isSignedIn: () => !!authStore.get(), _internals: { H, getYT, trackFromList, trackFromPanel } };
}
