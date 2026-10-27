// The app's data layer. Two sources, same data shapes:
//  - "device": the on-device engine (js/engine) talks to YouTube Music straight from the phone. No server needed.
//  - "server": your backend (Python) answers; it can be the website's own origin or a remote address.
// The native app defaults to "device"; the website defaults to "server".
import { loc, get as settings } from "./settings.js";

let token = "", base = "", source = "";
try {
  token = localStorage.getItem("token") || "";
  base = (localStorage.getItem("apiBase") || "").replace(/\/+$/, "");
  source = localStorage.getItem("source") || "";
  const u = new URL(location.href);
  const fromUrl = u.searchParams.get("token"), srcUrl = u.searchParams.get("source");
  if (fromUrl) { token = fromUrl; localStorage.setItem("token", token); u.searchParams.delete("token"); }
  if (srcUrl) { source = srcUrl; localStorage.setItem("source", source); u.searchParams.delete("source"); }   // dev: ?source=device
  if (fromUrl || srcUrl) history.replaceState(null, "", u.pathname + u.search + u.hash);
} catch {}

/** True inside the Capacitor (native) container. */
export const isNative = () => !!(window.Capacitor && window.Capacitor.isNativePlatform && window.Capacitor.isNativePlatform());
export const getSource = () => (source === "device" || source === "server" ? source : isNative() ? "device" : "server");
export const isDevice = () => getSource() === "device";
export const getBase = () => base;
export const getToken = () => token;
export function setSource(s) { source = s; try { localStorage.setItem("source", s); } catch {} configured = false; }
export function setConnection({ server, token: t }) {
  if (server !== undefined) { base = String(server).trim().replace(/\/+$/, ""); try { localStorage.setItem("apiBase", base); } catch {} }
  if (t !== undefined) { token = String(t).trim(); try { localStorage.setItem("token", token); } catch {} }
  configured = false;
}
const abs = (p) => base + p;

export const tk = (url) => {
  url = abs(url);
  return token ? url + (url.includes("?") ? "&" : "?") + "token=" + encodeURIComponent(token) : url;
};

/* ---------- the on-device engine (loaded only when needed) ---------- */
let eng = null, configured = false;
const withTimeout = (p, ms) => Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(new Error("timeout")), ms))]);
async function engine() {
  if (!eng && isNative() && base) {
    // If your PC server is reachable, use the engine it hosts: fixing a YouTube change then only needs a file update on the PC.
    try { eng = await withTimeout(import(/* @vite-ignore */ `${base}/js/engine/index.js`), 4000); } catch { eng = null; }
  }
  eng ??= await import("./engine/index.js");
  if (!configured) {                                   // in a browser (development) the engine goes through the backend's /dev/fetch proxy
    if (!isNative()) eng.configure({ devBase: base || location.origin, devToken: token });
    configured = true;
  }
  return eng;
}

/** Checks a server address (and token) without saving anything. Resolves to {ok, reason}. */
export async function testConnection(server, t) {
  const root = String(server || "").trim().replace(/\/+$/, "");
  try {
    const h = await fetch(root + "/health", { cache: "no-store" });
    if (!h.ok) return { ok: false, reason: `The server answered ${h.status}.` };
  } catch { return { ok: false, reason: "Couldn't reach that address. Is Tailscale connected and the PC backend running?" }; }
  try {
    const r = await fetch(`${root}/api/suggest?q=a${t ? "&token=" + encodeURIComponent(t) : ""}`, { cache: "no-store" });
    if (r.status === 401) return { ok: false, reason: "The server is reachable, but the access token is wrong." };
    if (!r.ok) return { ok: false, reason: `The server answered ${r.status}.` };
  } catch { return { ok: false, reason: "Reached the server, but a request was blocked." }; }
  return { ok: true };
}

/** Checks that the phone itself can reach YouTube Music (on-device mode). */
export async function testDevice() {
  try { const r = await (await engine()).handle("/api/suggest?q=a"); return r.length ? { ok: true } : { ok: false, reason: "YouTube answered, but with nothing useful." }; }
  catch (e) { return { ok: false, reason: "Couldn't reach YouTube Music from this device: " + String(e.message || e).slice(0, 120) }; }
}

/* ---------- optional Google sign-in (on-device source only; see Settings → Account) ---------- */
export const signedIn = () => { try { return isDevice() && !!localStorage.getItem("ytauth"); } catch { return false; } };
export const accountName = () => { try { return JSON.parse(localStorage.getItem("ytacct"))?.name || ""; } catch { return ""; } };
/** Starts Google's device sign-in. Resolves to { url, code, expiresIn, done }: type the code at the url; `done` settles on approval. */
export async function startSignIn() { return (await engine()).startSignIn(); }
export async function signOutYT() {
  try { await (await engine()).signOut(); } catch {}
  try { localStorage.removeItem("ytauth"); localStorage.removeItem("ytacct"); } catch {}
}

/** Clears saved cookies and starts the YouTube session over. Resolves to a sentence for the toast. */
export async function resetConnection() {
  if (!isDevice()) return "This is for the on-device music source.";
  try {
    const e = await engine();
    const state = await e.resetConnection();
    eng = null; configured = false;                                   // the next request builds the engine from scratch
    return state === "cleared" ? "Cookies cleared and a new session started. Try playing a song." : `Couldn't clear cookies (${state}). A new session was started anyway.`;
  } catch (e) { return "Reset failed: " + String(e.message || e).slice(0, 120); }
}

/** One-line report of the phone's network as YouTube sees it, for Settings → About → Connection check. */
export async function checkConnection() {
  if (!isDevice()) return "This check is for the on-device music source.";
  try {
    const d = await (await engine()).diagnose();
    const me = `Phone: IPv4 ${d.v4}, IPv6 ${d.v6}.`;
    const per = (d.clients?.length ? `\nPer client: ${d.clients.join(" · ")}` : "") + `\nCookies: ${d.cookies} · Account: ${d.signedIn ? "signed in" : "not signed in"}` + (d.info ? `\nYouTube sees this session as ${d.info.remoteHost} (visitor ${d.info.visitor}…)` : "") + `\nIPv4 client: ${d.v4client}\nAddress family iOS picks by itself, 6 requests: ${d.family}`;
    if (d.stream.error) return `${me} Stream refused: ${d.stream.error}${per}`;
    const same = [d.v4, d.v6].includes(d.stream.ip) ? "matches the phone" : "DIFFERENT from the phone";
    return `${me} Stream via ${d.stream.client} was issued for ${d.stream.ip} (${same}); audio check ${d.stream.status}.${per}`;
  } catch (e) { return "Check failed: " + String(e.message || e).slice(0, 160); }
}

/** Adds the chosen country to catalogue calls so charts, search and home match it. */
function withLoc(path) {
  if (!path.startsWith("/api/") || path.startsWith("/api/img") || path.startsWith("/api/lyrics") || /[?&]loc=/.test(path)) return path;
  const l = loc();
  return l ? path + (path.includes("?") ? "&" : "?") + "loc=" + l : path;
}

/* Native app / on-device mode: remember the last good answers so Home and Explore still open with no connection. */
const CK = "apicache", CACHE_MAX = 40, ITEM_MAX = 150000;
const readCache = () => { try { return JSON.parse(localStorage.getItem(CK)) || {}; } catch { return {}; } };
function putCache(path, data) {
  if (!(isNative() || isDevice()) || !path.startsWith("/api/") || /^\/api\/(radio|lyrics)/.test(path)) return;
  try {
    const s = JSON.stringify(data); if (s.length > ITEM_MAX) return;
    const c = readCache(); c[path] = { t: Date.now(), d: data };
    const keys = Object.keys(c).sort((a, b) => c[a].t - c[b].t);
    while (keys.length > CACHE_MAX) delete c[keys.shift()];
    localStorage.setItem(CK, JSON.stringify(c));
  } catch {}
}

export async function api(path) {
  path = withLoc(path);
  if (isDevice()) {
    try { const data = await (await engine()).handle(path); putCache(path, data); return data; }
    catch (e) {
      const hit = readCache()[path];
      if (hit) return hit.d;
      throw new Error(`${path} → ${e.status || "failed"}: ${String(e.message || e).slice(0, 100)}`);
    }
  }
  let r;
  try { r = await fetch(tk(path)); }
  catch (e) {                                              // offline or unreachable
    const hit = isNative() ? readCache()[path] : null;
    if (hit) return hit.d;
    throw e;
  }
  if (r.status === 401) {                                  // ask for the token in the app's own sheet
    document.dispatchEvent(new CustomEvent("need-connection", { detail: { reason: "token" } }));
    throw new Error(`${path} → 401`);
  }
  if (!r.ok) throw new Error(`${path} → ${r.status}`);
  const data = await r.json();
  putCache(path, data);
  return data;
}

/* ---------- audio ---------- */
const quality = (use) => (use === "dl" ? settings().dlQuality : settings().quality);

/** The address to play (or download) a song from. On-device it is a direct, phone-bound YouTube address. */
const streamInfo = new Map();                              // videoId → { approxMs, size }: what YouTube says the file is
export const expectedOf = (id) => streamInfo.get(id) || null;
export async function resolveStream(id, use = "play", { fresh = false } = {}) {
  if (isDevice()) {
    const r = await (await engine()).resolveStream(id, quality(use), fresh);
    streamInfo.set(id, { approxMs: r.approxMs || 0, size: r.size || 0 });
    if (r.degraded) document.dispatchEvent(new CustomEvent("limited-stream", { detail: r.client }));   // only the first minute of the song is served
    return r.url;
  }
  return tk(`/stream/${id}?q=${quality(use)}`) + (fresh ? `&r=${Date.now()}` : "");
}
/** One byte range of a resolved audio address (for offline saves): { blob, total, status }. */
export async function fetchRange(url, start, end) {
  if (isDevice()) return (await engine()).downloadRange(url, start, end);
  const r = await fetch(url, { headers: { Range: `bytes=${start}-${end}` } });
  const cr = r.headers.get("content-range");
  return { blob: await r.blob(), total: cr ? Number(cr.split("/")[1]) : 0, status: r.status };
}

/** Download a whole song with a few parallel bounded range requests (offline saves, Save to Files). onProgress(0..1). */
const FIRST_CHUNK = 1024 * 1024, CHUNK = 2 * 1024 * 1024, PARALLEL = 3;
async function ranged(url, start, end, total = 0) {
  for (let attempt = 0; ; attempt++) {
    try {
      const r = await fetchRange(url, start, end);
      if (r.status !== 206 && r.status !== 200) throw new Error(`audio ${r.status}`);
      if (r.status === 206) {                                // a piece must be exactly the bytes asked for
        const want = end - start + 1;
        if (r.blob.size > want) r.blob = r.blob.slice(0, want);
        else if (r.blob.size < want && !(total && end + 1 >= total)) throw new Error(`audio piece too short (${r.blob.size} of ${want})`);
      }
      return r;
    } catch (e) { if (attempt >= 1) throw e; }
  }
}
export async function downloadAudio(id, use = "play", onProgress = () => {}, fresh = false) {
  const url = await resolveStream(id, use, { fresh });
  const first = await ranged(url, 0, FIRST_CHUNK - 1, streamInfo.get(id)?.size || 0);
  const total = streamInfo.get(id)?.size || first.total || first.blob.size;
  if (first.status === 200 || first.blob.size >= total) { onProgress(1); return new Blob([first.blob.slice(0, total)], { type: "audio/mp4" }); }
  const jobs = [];
  for (let s = first.blob.size; s < total; s += CHUNK) jobs.push([s, Math.min(s + CHUNK, total) - 1]);
  const got = new Array(jobs.length);
  let done = first.blob.size, next = 0;
  onProgress(done / total);
  await Promise.all(Array.from({ length: Math.min(PARALLEL, jobs.length) }, async () => {
    while (next < jobs.length) {
      const i = next++, [from, to] = jobs[i];
      const r = await ranged(url, from, to, total);
      got[i] = r.blob; done += r.blob.size; onProgress(Math.min(1, done / total));
    }
  }));
  const whole = new Blob([first.blob, ...got], { type: "audio/mp4" });
  if (whole.size < total) throw new Error(`audio incomplete (${whole.size} of ${total})`);
  return whole.size > total ? whole.slice(0, total, "audio/mp4") : whole;
}

/** What the player loads: a direct address, in both modes. On-device it is a phone-bound YouTube address. */
export async function getAudio(id, use = "play", { fresh = false, asBlob = false } = {}) {
  if (asBlob) { const b = await downloadAudio(id, use, () => {}, fresh); return { url: URL.createObjectURL(b), blob: true, size: b.size }; }   // fetch with the app's own HTTP, play from memory
  return { url: await resolveStream(id, use, { fresh }), blob: false };
}
/** Get the next song's address ready so the hand-off is quick. */
export function warmStream(id) {
  if (isDevice()) { resolveStream(id).catch(() => {}); return; }
  fetch(tk(`/stream/${id}?q=${quality("play")}`), { headers: { Range: "bytes=0-1" } }).catch(() => {});
}

// Thumbnails: through the backend's image proxy in server mode, straight from Google in on-device mode.
const BLANK = "data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==";   // 1×1 transparent: no broken-image icons
function directArt(u, s) {
  try { if (/(googleusercontent|ggpht)\.com$/.test(new URL(u).hostname)) return u.replace(/=[ws]\d+(-h\d+)?.*$/, `=w${s}-h${s}-l90-rj`); } catch {}
  return u;
}
export const art = (u, s = 300) => (!u ? BLANK : isDevice() ? directArt(u, s) : abs(`/api/img?u=${encodeURIComponent(u)}&s=${s}`));

export const fmtTime = (s) => {
  if (!isFinite(s) || s < 0) s = 0;
  const m = Math.floor(s / 60), r = Math.floor(s % 60);
  return `${m}:${String(r).padStart(2, "0")}`;
};
