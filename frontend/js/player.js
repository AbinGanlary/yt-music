// Playback engine: one persistent <audio> element (required for iOS background audio),
// a queue that tops itself up from YouTube Music radio, and Media Session lock-screen controls.
// With "Dynamic queue" on, top-ups are re-ranked by what you finish, skip and like.
import { api, getAudio, downloadAudio, warmStream, art, expectedOf } from "./api.js";
import * as store from "./store.js";
import * as settings from "./settings.js";

export const audio = document.getElementById("a");
export const bus = new EventTarget();
const emit = (name, detail) => bus.dispatchEvent(new CustomEvent(name, { detail }));

export const state = { queue: [], idx: -1, shuffle: false, repeat: "off" };
export const current = () => state.queue[state.idx] || null;

let blobUrl = null, seq = 0, extending = false, warmedFor = null, lastSave = 0, lastPos = 0, retried = false, blobTried = false, recordedFor = null;

function revoke() { if (blobUrl) { URL.revokeObjectURL(blobUrl); blobUrl = null; } }

/* ---------- how a song reaches the player: stream it, or download it first ---------- */
// Settings → Playback: "auto" streams, and switches to download-first once streaming was rejected twice in a row
// (it tries streaming again every 8th song); "stream" never downloads; "download" always downloads first.
const mode = () => settings.get().playback || "auto";
const fbStreak = () => store.kv.get("fbStreak", 0);
const v4Downloads = () => window.__v4 === "active";                                  // the IPv4 client is active: fetch songs with it, then play them from memory
const downloadMode = () => mode() === "download" || (mode() === "auto" && (fbStreak() >= 2 || v4Downloads()));
let plays = 0, curMethod = "stream", noted = false;
const pre = new Map();                                      // videoId → Promise<Blob|null>: the next song, fetched in advance
/** Remember how a song was delivered (shown in Settings → About) and whether streaming keeps failing. */
function noteMethod(m) {
  store.kv.set("lastPlay", { m, at: Date.now() });
  if (m === "fallback") store.kv.set("fbStreak", fbStreak() + 1);
  else if (m === "stream") store.kv.set("fbStreak", 0);
}
/** While this song plays, fetch the next one so it starts at once. Only when songs are being downloaded anyway. */
function prefetchNext() {
  const n = state.queue[state.idx + 1];
  if (!downloadMode() || !n || warmedFor === n.videoId || !navigator.onLine || store.downloadedIds.has(n.videoId)) return;
  warmedFor = n.videoId;
  while (pre.size >= 2) pre.delete(pre.keys().next().value);
  pre.set(n.videoId, downloadAudio(n.videoId, "play").catch(() => null));
}

/* ---------- SponsorBlock: skip non-music parts of music videos (Settings → Playback, off by default) ---------- */
const sbCache = new Map();
let segs = [];                                           // [[start, end], …] for the current song
async function loadSegments(id) {
  segs = [];
  if (!settings.get().sponsorBlock || !navigator.onLine) return;
  let s = sbCache.get(id);
  if (!s) {
    try {
      const cats = encodeURIComponent('["music_offtopic","intro","outro","selfpromo","sponsor","interaction"]');
      const r = await fetch(`https://sponsor.ajay.app/api/skipSegments?videoID=${id}&categories=${cats}&actionTypes=${encodeURIComponent('["skip"]')}`);
      s = r.ok ? (await r.json()).map((x) => x.segment).filter((x) => x?.length === 2) : [];
    } catch { s = []; }
    sbCache.set(id, s);
  }
  if (current()?.videoId === id) segs = s;
}
function skipSegments() {
  if (!segs.length) return;
  const c = audio.currentTime, hit = segs.find(([a, b]) => c >= a && c < b - 0.6);
  if (hit) audio.currentTime = hit[1];
}

/** Notes how long the player thinks a downloaded song is, next to what YouTube says (Settings → About → Last song played). */
function watchBlobLength(id, size) {
  audio.addEventListener("loadedmetadata", () => {
    const exp = expectedOf(id);
    if (exp?.approxMs && current()?.videoId === id) store.kv.set("lastPlayInfo", { size, expected: exp.size, got: audio.duration, want: exp.approxMs / 1000 });
  }, { once: true });
}

/**
 * The song's length. iOS sometimes reads these audio files as twice as long (and then plays silence after the real
 * end), so when the element's duration is far above what YouTube says, trust YouTube.
 */
export function duration() {
  const d = audio.duration, e = (expectedOf(current()?.videoId)?.approxMs || 0) / 1000;
  return e && isFinite(d) && d > e * 1.5 ? e : isFinite(d) ? d : 0;
}
/* ---------- listening signals ---------- */
const artistOf = (t) => (t?.artists?.[0] || "").toLowerCase();

/** Log how a song ended: finished, skipped early, or partly heard. Called once per loaded song. */
function finishCurrent(ended) {
  const t = current();
  if (!t || recordedFor === t.videoId) return;
  recordedFor = t.videoId;
  const d = duration(), c = audio.currentTime;
  if (!d || !isFinite(d)) return;
  const frac = ended ? 1 : c / d;
  if (!ended && c < 8) { if (c < 2) return; }          // ignore accidental taps
  const skipped = !ended && frac < 0.3;
  store.pushSignal({ t: store.slim(t), frac: Math.round(frac * 100) / 100, skipped });
  store.logPlay(t, ended ? d : c);                      // feeds the Analytics tab
  if (skipped && settings.get().dynamic) pruneAfterSkip(t);
}

/** Skipped an artist twice recently? Stop lining up more of them in the next few slots. */
function pruneAfterSkip(t) {
  const a = artistOf(t);
  if (!a) return;
  const recent = store.getSignals().slice(-20);
  const skips = recent.filter((s) => s.skipped && artistOf(s.t) === a).length;
  if (skips < 2) return;
  const upto = Math.min(state.queue.length, state.idx + 9);
  let removed = 0;
  for (let i = upto - 1; i > state.idx; i--) {
    if (artistOf(state.queue[i]) === a) { state.queue.splice(i, 1); removed++; }
  }
  if (removed) emit("queue");
}

/** Per-artist affinity from everything the app has learned (likes, finishes, skips, picked artists). */
function affinity() {
  const m = new Map();
  const add = (name, v) => { if (name) m.set(name, (m.get(name) || 0) + v); };
  store.getLikes().forEach((t) => add(artistOf(t), 1));
  store.getSignals().slice(-120).forEach((s) => add(artistOf(s.t), s.skipped ? -1 : s.frac >= 0.8 ? 0.5 : 0.1));
  settings.getTaste().artists.forEach((a) => add((a.name || "").toLowerCase(), 2));
  store.getDislikes().forEach((t) => add(artistOf(t), -1.5));
  return m;
}

/** Songs worth seeding extra radios from: liked or finished, not currently queued. */
function pickAnchors(n) {
  const inQueue = new Set(state.queue.map((t) => t.videoId));
  const pool = new Map();
  store.getLikes().forEach((t) => pool.set(t.videoId, t));
  store.getSignals().slice(-80).forEach((s) => { if (!s.skipped && s.frac >= 0.8) pool.set(s.t.videoId, s.t); });
  const list = [...pool.values()].filter((t) => !inQueue.has(t.videoId));
  for (let i = list.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [list[i], list[j]] = [list[j], list[i]]; }
  return list.slice(0, n);
}

function rank(cands) {
  const aff = affinity();
  const dis = new Set(store.getDislikes().map((t) => t.videoId));
  cands = cands.filter((c) => !dis.has(c.t.videoId));
  const skippedIds = new Set(store.getSignals().filter((s) => s.skipped).map((s) => s.t.videoId));
  const doneIds = new Set(store.getSignals().filter((s) => !s.skipped && s.frac >= 0.8).map((s) => s.t.videoId));
  return cands
    .filter((c) => !(skippedIds.has(c.t.videoId) && !doneIds.has(c.t.videoId)))
    .map((c) => {
      const a = aff.get(artistOf(c.t)) || 0;
      return { ...c, score: c.score + Math.max(-1.5, Math.min(1.5, a * 0.35)) };
    })
    .sort((x, y) => y.score - x.score);
}

/** Keep a few songs queued ahead. Dynamic: blend radios from the last song plus songs you've loved. */
async function topUp(force = false, plain = false) {
  if (extending || !navigator.onLine || !settings.get().autoplay) return false;
  if (!force && state.queue.length - state.idx > 3) return false;
  const last = state.queue[state.queue.length - 1];
  if (!last) return false;
  extending = true;
  try {
    const dynamic = settings.get().dynamic && !plain;
    const seeds = [last, ...(dynamic ? pickAnchors(2) : [])];
    const lists = await Promise.all(seeds.map((s) => api(`/api/radio/${s.videoId}`).catch(() => [])));
    let cands = [];
    lists.forEach((l, li) => l.forEach((t, i) => cands.push({ t, score: 1 - i / Math.max(1, l.length) + (li === 0 ? 0.15 : 0) })));
    if (dynamic) cands = rank(cands);
    const seen = new Set(state.queue.map((t) => t.videoId));
    const more = [];
    for (const c of cands) if (!seen.has(c.t.videoId)) { seen.add(c.t.videoId); more.push(c.t); if (more.length >= 25) break; }
    if (more.length) { state.queue.push(...more); emit("queue"); return true; }
  } catch {} finally { extending = false; }
  return false;
}

/* ---------- loading & queue ---------- */
async function load(track, { autoplay = true, at = 0, force = false } = {}) {
  const my = ++seq;
  retried = false; blobTried = false;
  if (!force) patience = 0;
  warmedFor = null;
  recordedFor = null;
  revoke();
  emit("track", track);
  setSession(track);
  const origId = track.videoId;
  if (track.video && !track.swapped && navigator.onLine && !(await store.getDownload(track.videoId).catch(() => null))) {
    // a music video: play YouTube Music's song version instead (album art, clean title), as the official app does
    const c = await Promise.race([api(`/api/counterpart/${track.videoId}?title=${encodeURIComponent(track.title || "")}&artist=${encodeURIComponent((track.artists || []).join(", "))}&dur=${encodeURIComponent(track.duration || "")}`), new Promise((r) => setTimeout(() => r(null), 3000))]).catch(() => null);
    if (my !== seq) return;
    if (c?.videoId) { track = { ...c, swapped: true }; if (state.queue[state.idx]?.videoId === origId) state.queue[state.idx] = track; emit("track", track); emit("queue"); setSession(track); }
    else { track.swapped = true; }
  }
  loadSegments(track.videoId);
  if (autoplay) store.pushHistory(track);
  const dl = await store.getDownload(track.videoId).catch(() => null);
  if (my !== seq) return;
  noted = false;
  if (dl) { blobUrl = URL.createObjectURL(dl.blob); audio.src = blobUrl; curMethod = "offline"; }
  else {
    try {
      let src = null;
      const ahead = pre.get(track.videoId);
      if (ahead) {
        pre.delete(track.videoId);
        const b = await ahead;
        if (b) { src = { url: URL.createObjectURL(b), blob: true, size: b.size }; curMethod = "prefetch"; }
      }
      if (!src) {
        const first = ++plays % 8 !== 0 || mode() !== "auto";     // every 8th song in Auto re-tests streaming
        const dlFirst = mode() === "download" || (mode() === "auto" && (v4Downloads() || fbStreak() >= 2) && first);
        src = await getAudio(track.videoId, "play", { asBlob: dlFirst, fresh: force ? 2 : false });   // force: a new YouTube session
        curMethod = dlFirst ? "download" : "stream";
      }
      if (my !== seq) { if (src.blob) URL.revokeObjectURL(src.url); return; }
      if (src.blob) blobUrl = src.url;
      audio.src = src.url;
      if (src.blob) watchBlobLength(track.videoId, src.size);
    }
    catch (e) {                                           // couldn't get an address (offline, or YouTube refused)
      if (my !== seq) return;
      recordedFor = track.videoId;
      giveUp(`No stream: ${String(e?.message || e).slice(0, 140)}`, navigator.onLine);
      return;
    }
    if (my !== seq) return;
  }
  if (at) audio.addEventListener("loadedmetadata", () => { audio.currentTime = at; }, { once: true });
  if (autoplay) { try { await audio.play(); } catch { emit("blocked"); } }
  topUp();
}

export function go(i) {
  if (i < 0 || i >= state.queue.length) return;
  finishCurrent(false);
  state.idx = i;
  emit("queue");
  load(state.queue[i]);
}

/** Replace the queue with `list` and start at `i`. */
export function playList(list, i = 0) {
  const base = list.filter((t) => t.videoId);
  finishCurrent(false);
  state.idx = -1;
  i = Math.max(0, Math.min(i, base.length - 1));
  if (state.shuffle && base.length > 1) {       // chosen song first, the rest shuffled
    const rest = base.filter((_, k) => k !== i);
    for (let k = rest.length - 1; k > 0; k--) { const j = Math.floor(Math.random() * (k + 1)); [rest[k], rest[j]] = [rest[j], rest[k]]; }
    state.queue = [base[i], ...rest];
    go(0);
  } else {
    state.queue = base.slice();
    go(i);
  }
}
export function playNext(t) {
  if (!state.queue.length) return playList([t]);
  state.queue = state.queue.filter((x, k) => x.videoId !== t.videoId || k === state.idx);
  state.queue.splice(state.idx + 1, 0, t);
  emit("queue");
}
export function addToQueue(t) {
  if (!state.queue.length) return playList([t]);
  if (!state.queue.some((x) => x.videoId === t.videoId)) state.queue.push(t);
  emit("queue");
}
export function removeAt(i) {
  if (i === state.idx || i < 0 || i >= state.queue.length) return;
  state.queue.splice(i, 1);
  if (i < state.idx) state.idx--;
  emit("queue");
}
/** Start a radio seeded by one song (plain: songs like this one, not blended with your other taste). */
export async function startRadio(t) {
  playList([t]);
  await topUp(true, true);
}

function shuffleUpcoming(from = state.idx) {
  const head = state.queue.slice(0, from + 1), tail = state.queue.slice(from + 1);
  for (let k = tail.length - 1; k > 0; k--) { const j = Math.floor(Math.random() * (k + 1)); [tail[k], tail[j]] = [tail[j], tail[k]]; }
  state.queue = head.concat(tail);
}
export function toggleShuffle() {
  state.shuffle = !state.shuffle;
  if (state.shuffle) { shuffleUpcoming(); emit("queue"); }
  emit("mode");
}
export function cycleRepeat() {
  state.repeat = state.repeat === "off" ? "all" : state.repeat === "all" ? "one" : "off";
  emit("mode");
}

export function toggle() {
  if (!current()) return;
  if (audio.paused) audio.play().catch(() => emit("blocked")); else audio.pause();
}
export function seek(t) { const d = duration(); if (d) { audio.currentTime = Math.max(0, Math.min(t, d - 0.3)); updatePosition(); } }

export function next(fromEnded = false) {
  if (state.repeat === "one" && fromEnded) { audio.currentTime = 0; audio.play().catch(() => {}); return; }
  if (state.idx + 1 < state.queue.length) return go(state.idx + 1);
  if (state.repeat === "all" && state.queue.length) return go(0);
  topUp(true).then(() => { if (state.idx + 1 < state.queue.length) go(state.idx + 1); else emit("state"); });
}
export function prev() {
  if (audio.currentTime > 3 || state.idx <= 0) { audio.currentTime = 0; return; }
  go(state.idx - 1);
}

/* ---------- speed, sleep timer, dislike ---------- */
export const SPEEDS = [1, 1.25, 1.5, 2, 0.75];
export const SLEEPS = [0, 15, 30, 60];                  // minutes; 0 = off
export const extras = { speedIdx: 0, sleepIdx: 0 };
let sleepTimer = null;

export function cycleSpeed() {
  extras.speedIdx = (extras.speedIdx + 1) % SPEEDS.length;
  audio.defaultPlaybackRate = audio.playbackRate = SPEEDS[extras.speedIdx];
  emit("mode");
}
export function cycleSleep() {
  extras.sleepIdx = (extras.sleepIdx + 1) % SLEEPS.length;
  clearTimeout(sleepTimer);
  const mins = SLEEPS[extras.sleepIdx];
  if (mins) sleepTimer = setTimeout(() => {
    audio.pause(); extras.sleepIdx = 0; emit("mode"); emit("toast", "Sleep timer: playback stopped");
  }, mins * 60000);
  emit("mode");
}

/** Thumbs-down: never queue this song again, and lean away from its artist. */
export function dislike(t) {
  const now = store.toggleDislike(t);
  if (now) {
    store.pushSignal({ t: store.slim(t), frac: 0, skipped: true, disliked: true });
    state.queue = state.queue.filter((x, i) => x.videoId !== t.videoId || i <= state.idx);
    if (current()?.videoId === t.videoId) { recordedFor = t.videoId; next(); }
    else emit("queue");
  }
  return now;
}

/* ---------- events from the element ---------- */
audio.addEventListener("play", () => { document.body.classList.add("playing"); navigator.mediaSession && (navigator.mediaSession.playbackState = "playing"); emit("state"); });
audio.addEventListener("pause", () => { document.body.classList.remove("playing"); navigator.mediaSession && (navigator.mediaSession.playbackState = "paused"); emit("state"); });
audio.addEventListener("ended", () => {
  if (audio.currentTime < 1 && !blobUrl) { recover(); return; }      // "ended" right away means the stream was cut, not a finished song
  finishCurrent(true); next(true);
});
audio.addEventListener("durationchange", () => { updatePosition(); emit("time"); });
audio.addEventListener("timeupdate", () => {
  emit("time");
  skipSegments();
  const d = duration();
  if (d && isFinite(audio.duration) && audio.duration > d * 1.5 && audio.currentTime >= d - 0.25 && recordedFor !== current()?.videoId) { finishCurrent(true); next(true); return; }   // the real end of a song the player thinks is twice as long
  const now = Date.now();
  if (now - lastPos > 1000) { lastPos = now; updatePosition(); }
  if (now - lastSave > 5000) { lastSave = now; saveSession(); }
  // warm the next stream so the hand-off is quick
  const n = state.queue[state.idx + 1];
  if (n && !downloadMode() && warmedFor !== n.videoId && audio.duration && audio.currentTime / audio.duration > 0.25 && !store.downloadedIds.has(n.videoId) && navigator.onLine) {
    warmedFor = n.videoId;
    warmStream(n.videoId);
  }
});
audio.addEventListener("error", () => recover());
/** The element couldn't play the address. Try a fresh address, then fetch the file with the app's own HTTP and play it from memory. */
function recover() {
  const t = current();
  if (!t) return;
  const code = audio.error?.code, host = (() => { try { return new URL(audio.currentSrc || audio.src).hostname.split(".")[0]; } catch { return "?"; } })();
  const reason = `Audio error ${code ?? "?"}${audio.error?.message ? " (" + audio.error.message.slice(0, 60) + ")" : ""} from ${host}`;
  const stage = !retried ? "fresh" : !blobTried && !blobUrl && mode() !== "stream" ? "blob" : null;
  if (!stage) { recordedFor = t.videoId; giveUp(reason, navigator.onLine); return; }   // a broken stream isn't a taste signal
  if (stage === "fresh") retried = true; else blobTried = true;
  const at = audio.currentTime, my = seq;
  (async () => {
    try {
      const src = await getAudio(t.videoId, "play", { fresh: stage === "blob" ? 2 : 1, asBlob: stage === "blob" });   // 2 = also start a new YouTube session
      if (my !== seq) { if (src.blob) URL.revokeObjectURL(src.url); return; }
      if (src.blob) { blobUrl = src.url; curMethod = "fallback"; }
      audio.src = src.url;
    }
    catch (e) { if (my !== seq) return; recordedFor = t.videoId; giveUp(`${reason}; retry failed: ${String(e?.message || e).slice(0, 100)}`, true); return; }
    audio.addEventListener("loadedmetadata", () => { if (at) audio.currentTime = at; audio.play().catch(() => {}); }, { once: true });
  })();
}

/**
 * A song couldn't play. YouTube sometimes refuses the first addresses of a fresh app launch and accepts them a little
 * later, so try the same song again a few times (new session each time) before moving on. Then skip, but after two
 * songs in a row stop and say why instead of racing through the queue.
 */
let failStreak = 0, patience = 0;
function giveUp(reason, canSkip) {
  const t = current();
  if (canSkip && t && patience < 3) {
    patience++;
    const my = seq;
    emit("toast", `Getting the stream ready, trying again (${patience}/3)…`);
    setTimeout(() => { if (my === seq && current() === t && audio.paused) load(t, { force: true }); }, 6000);
    return;
  }
  patience = 0;
  failStreak++;
  if (!canSkip) { emit("toast", "Offline: that song isn't saved"); return; }
  if (failStreak >= 2) { failStreak = 0; audio.pause(); emit("toast", `Can't play: ${reason}`); return; }
  emit("toast", `${reason}. Skipping`);
  next();
}
audio.addEventListener("playing", () => {
  failStreak = 0; patience = 0;
  if (!noted) { noted = true; noteMethod(curMethod); }
  prefetchNext();
});

/* ---------- lock screen / Bluetooth controls ---------- */
function setSession(t) {
  if (!("mediaSession" in navigator)) return;
  const abs = (p) => new URL(p, location.href).href;
  navigator.mediaSession.metadata = new MediaMetadata({
    title: t.title, artist: (t.artists || []).join(", "), album: t.album || "",
    artwork: t.thumbnail ? [{ src: abs(art(t.thumbnail, 512)), sizes: "512x512", type: "image/jpeg" }] : [],
  });
}
function updatePosition() {
  if (!("mediaSession" in navigator) || !navigator.mediaSession.setPositionState) return;
  const d = duration(); if (!d) return;
  try { navigator.mediaSession.setPositionState({ duration: d, playbackRate: 1, position: Math.min(audio.currentTime, d) }); } catch {}
}
/**
 * Lock screen / Control Center buttons. iOS shows previous / next track only while those handlers exist, and falls back
 * to ±10 s buttons otherwise, so they are registered again every time playback starts or the song changes.
 */
function bindSession() {
  if (!("mediaSession" in navigator)) return;
  const ms = navigator.mediaSession;
  const set = (a, f) => { try { ms.setActionHandler(a, f); } catch { /* not supported here */ } };
  set("play", () => toggle());
  set("pause", () => toggle());
  set("previoustrack", () => prev());
  set("nexttrack", () => next());
  set("seekto", (d) => seek(d.seekTime));
  set("seekbackward", null);                             // with these, iOS shows ±10 s instead of previous / next
  set("seekforward", null);
}
bindSession();
audio.addEventListener("playing", bindSession);
audio.addEventListener("loadedmetadata", bindSession);

/* ---------- remember where you were ---------- */
function saveSession() {
  if (!current()) return;
  store.kv.set("session", { queue: state.queue.slice(0, 120), idx: Math.min(state.idx, 119), t: audio.currentTime || 0 });
}
window.addEventListener("pagehide", saveSession);
document.addEventListener("visibilitychange", () => { if (document.hidden) saveSession(); });

export function restore() {
  const s = store.kv.get("session", null);
  if (!s || !s.queue?.length) return;
  state.queue = s.queue; state.idx = Math.min(s.idx, s.queue.length - 1);
  load(state.queue[state.idx], { autoplay: false, at: s.t });
  emit("queue");
}
