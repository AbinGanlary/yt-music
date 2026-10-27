// Local persistence: likes + history in localStorage, offline downloads (audio blobs) in IndexedDB.
import { downloadAudio, tk, isDevice, getBase } from "./api.js";
import * as S from "./settings.js";

const read = (k, d) => { try { return JSON.parse(localStorage.getItem(k)) ?? d; } catch { return d; } };
const write = (k, v) => { try { localStorage.setItem(k, JSON.stringify(v)); } catch {} };
export const slim = (t) => ({ videoId: t.videoId, title: t.title, artists: t.artists, artistIds: t.artistIds, album: t.album, duration: t.duration, thumbnail: t.thumbnail, ...(t.video ? { video: true } : {}), ...(t.swapped ? { swapped: true } : {}) });

/* ---- listening signals (what you finished, skipped, liked) used by the dynamic queue ---- */
export const getSignals = () => read("signals", []);
export function pushSignal(ev) {
  if (!S.get().saveHistory) return;
  const s = getSignals();
  s.push({ ...ev, at: Date.now() });
  write("signals", s.slice(-250));
}
export const clearSignals = () => write("signals", []);

export const kv = { get: read, set: write };

/* ---- likes & history ---- */
export const getLikes = () => read("likes", []);
export const isLiked = (id) => getLikes().some((t) => t.videoId === id);
export function toggleLike(t) {
  const likes = getLikes();
  const i = likes.findIndex((x) => x.videoId === t.videoId);
  if (i >= 0) likes.splice(i, 1); else likes.unshift(slim(t));
  write("likes", likes);
  return i < 0;
}
export const getHistory = () => read("history", []);
export function pushHistory(t) {
  if (!S.get().saveHistory) return;
  const h = getHistory().filter((x) => x.videoId !== t.videoId);
  h.unshift(slim(t));
  write("history", h.slice(0, 60));
}
export const clearHistory = () => write("history", []);

export const getRecentSearches = () => read("recent", []);
export function addRecentSearch(q) {
  const r = getRecentSearches().filter((x) => x.toLowerCase() !== q.toLowerCase());
  r.unshift(q);
  write("recent", r.slice(0, 8));
}
export const clearRecentSearches = () => write("recent", []);

/* ---- dislikes: "don't play this again" for the dynamic queue ---- */
export const getDislikes = () => read("dislikes", []);
export const isDisliked = (id) => getDislikes().some((t) => t.videoId === id);
export function toggleDislike(t) {
  const d = getDislikes();
  const i = d.findIndex((x) => x.videoId === t.videoId);
  if (i >= 0) d.splice(i, 1); else d.unshift(slim(t));
  write("dislikes", d.slice(0, 300));
  return i < 0;
}

/* ---- listening stats (Analytics tab): a compact play log, [unix seconds, videoId, seconds listened], plus names for the ids ---- */
const emptyStats = () => ({ log: [], meta: {} });
export const getStats = () => { const s = read("stats", null); return s && Array.isArray(s.log) ? s : emptyStats(); };
export const clearStats = () => write("stats", emptyStats());
export function logPlay(t, secs) {
  if (!S.get().saveHistory || !t?.videoId || !(secs >= 10)) return;
  const s = getStats();
  s.log.push([Math.floor(Date.now() / 1000), t.videoId, Math.round(secs)]);
  if (s.log.length > 6000) s.log = s.log.slice(-5000);
  s.meta[t.videoId] = [t.title || "", (t.artists || []).join(", "), t.thumbnail || "", (t.artistIds || [])[0] || ""];
  if (Object.keys(s.meta).length > 1800) { const live = new Set(s.log.map((e) => e[1])); for (const k of Object.keys(s.meta)) if (!live.has(k)) delete s.meta[k]; }
  write("stats", s);
}

/* ---- genres for the Mix tab: names you add; each one is searched for songs and playlists ---- */
export const getGenres = () => read("genres", []);
export function addGenre(name) {
  const list = getGenres();
  const id = name.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, "-").replace(/^-+|-+$/g, "") || "g" + Date.now().toString(36);
  if (list.some((g) => g.id === id)) return { added: false, id };
  list.push({ id, name, at: Date.now() });
  write("genres", list);
  return { added: true, id };
}
export const removeGenre = (id) => write("genres", getGenres().filter((g) => g.id !== id));

/* ---- library: your own playlists + saved albums, playlists and artists ---- */
const lib = () => read("library", { playlists: [], saved: [] });
const saveLib = (l) => write("library", l);
export const getPlaylists = () => lib().playlists;
export const getPlaylist = (id) => lib().playlists.find((p) => p.id === id);
export function createPlaylist(name, tracks = []) {
  const l = lib();
  const id = "L" + Date.now().toString(36) + Math.random().toString(36).slice(2, 5);
  l.playlists.unshift({ id, name: name.trim() || "New playlist", tracks: tracks.map(slim), at: Date.now() });
  saveLib(l);
  return id;
}
export function renamePlaylist(id, name) {
  const l = lib(); const p = l.playlists.find((x) => x.id === id);
  if (p && name.trim()) { p.name = name.trim(); saveLib(l); }
}
export function deletePlaylist(id) { const l = lib(); l.playlists = l.playlists.filter((p) => p.id !== id); saveLib(l); }
export function addToPlaylist(id, t) {
  const l = lib(); const p = l.playlists.find((x) => x.id === id);
  if (!p || p.tracks.some((x) => x.videoId === t.videoId)) return false;
  p.tracks.push(slim(t)); saveLib(l);
  return true;
}
export function removeFromPlaylist(id, videoId) {
  const l = lib(); const p = l.playlists.find((x) => x.id === id);
  if (p) { p.tracks = p.tracks.filter((x) => x.videoId !== videoId); saveLib(l); }
}
export const getSaved = () => lib().saved;
export const isSaved = (kind, id) => lib().saved.some((x) => x.kind === kind && x.id === id);
/** Save/unsave an album, a YouTube playlist or an artist in the library. Returns true when now saved. */
export function toggleSaved(item) {
  const l = lib(); const i = l.saved.findIndex((x) => x.kind === item.kind && x.id === item.id);
  if (i >= 0) l.saved.splice(i, 1);
  else l.saved.unshift({ kind: item.kind, id: item.id, title: item.title, subtitle: item.subtitle || "", thumbnail: item.thumbnail || null, at: Date.now() });
  saveLib(l);
  return i < 0;
}

/* ---- downloads (IndexedDB) ---- */
let dbp;
const db = () =>
  (dbp ??= new Promise((res, rej) => {
    const r = indexedDB.open("grooves", 1);
    r.onupgradeneeded = () => r.result.createObjectStore("downloads", { keyPath: "videoId" });
    r.onsuccess = () => res(r.result);
    r.onerror = () => rej(r.error);
  }));
const tx = async (mode, fn) => {
  const d = await db();
  return new Promise((res, rej) => {
    const t = d.transaction("downloads", mode);
    const req = fn(t.objectStore("downloads"));
    t.oncomplete = () => res(req?.result);
    t.onerror = () => rej(t.error);
    t.onabort = () => rej(t.error);
  });
};

export const downloadedIds = new Set();
export async function initDownloads() {
  try {
    const keys = await tx("readonly", (s) => s.getAllKeys());
    (keys || []).forEach((k) => downloadedIds.add(k));
  } catch {}
}
export const getDownload = (id) => (downloadedIds.has(id) ? tx("readonly", (s) => s.get(id)) : Promise.resolve(null));
export const listDownloads = async () => ((await tx("readonly", (s) => s.getAll())) || []).sort((a, b) => b.at - a.at);
export async function putDownload(rec) {
  await tx("readwrite", (s) => s.put(rec));
  downloadedIds.add(rec.videoId);
}
export async function delDownload(id) {
  await tx("readwrite", (s) => s.delete(id));
  downloadedIds.delete(id);
}

/** Fetch the whole audio file via bounded range requests (works on-device and through the server). */
export const fetchAudio = (track, onProgress = () => {}) => downloadAudio(track.videoId, "dl", onProgress);

/** Fetch the audio and keep it for offline play. */
export async function download(track, onProgress = () => {}) {
  const blob = await fetchAudio(track, onProgress);
  await putDownload({ videoId: track.videoId, track: slim(track), blob, size: blob.size, at: Date.now() });
  try { await navigator.storage?.persist?.(); } catch {}
  onProgress(1);
}

/** The full song as a file: the saved copy if there is one, otherwise fetched now (not stored). */
export async function songBlob(track, onProgress) {
  const saved = await getDownload(track.videoId).catch(() => null);
  return saved ? saved.blob : fetchAudio(track, onProgress);
}

/** A short clip (for ringtones), cut on the server. */
export async function ringtoneBlob(track, start, dur) {
  if (isDevice() && !getBase()) throw new Error("needs-server");      // cutting audio happens on your PC server
  const r = await fetch(tk(`/api/ringtone/${track.videoId}?start=${start.toFixed(1)}&dur=${dur}`));
  if (!r.ok) throw new Error(`ringtone ${r.status}`);
  return r.blob();
}
