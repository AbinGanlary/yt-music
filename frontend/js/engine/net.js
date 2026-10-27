// Network for the on-device engine.
//  - inside the native app: Capacitor's native HTTP (no CORS, can send any header, e.g. the iOS client's User-Agent)
//  - in a browser (development only): through the backend's /dev/fetch proxy, which needs DEV_PROXY=1 on the server
const MOBILE_UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";
const WEB_CLIENT_IDS = new Set(["1", "56", "67"]);          // WEB, WEB_EMBEDDED_PLAYER, WEB_REMIX (YouTube Music)

const nativeHttp = () => {
  const c = window.Capacitor;
  if (!(c && c.isNativePlatform && c.isNativePlatform())) return null;
  return c.Plugins?.CapacitorHttp ?? c.registerPlugin?.("CapacitorHttp") ?? null;
};
/**
 * The app's own IPv4-only HTTPS client (native plugin "Ipv4Http", ios-app/native/Ipv4Http.swift). iOS picks IPv4 or IPv6
 * for each new connection, and YouTube answers the strict clients (VISIONOS, ANDROID_VR) over IPv6 with "sign in to
 * confirm you're not a bot" while accepting IPv4, which is also what the working PC test uses. The plugin always uses
 * IPv4, a fresh connection per request, and keeps no cookies or cache. Without it (or if it fails) Capacitor's HTTP is used.
 */
let v4State = "not tried";                                    // "active" | "missing" | "error: …"
export const v4Status = () => v4State;
const v4Plugin = () => {
  const c = window.Capacitor;
  if (!(c && c.isNativePlatform && c.isNativePlatform())) return null;
  try { return c.Plugins?.Ipv4Http ?? c.registerPlugin?.("Ipv4Http") ?? null; } catch { return null; }
};
async function viaV4(opts) {
  if (v4State === "missing") return null;
  const p = v4Plugin();
  if (!p) { v4State = window.__v4 = "missing"; return null; }
  try { const r = await p.request(opts); v4State = window.__v4 = "active"; return r; }
  catch (e) {
    const m = String(e?.message || e || "");
    if (/not implemented|unimplemented|not available/i.test(m) || e?.code === "UNIMPLEMENTED") v4State = window.__v4 = "missing";
    else v4State = "error: " + m.slice(0, 60);
    return null;
  }
}
const hget = (h, name) => { for (const k in h || {}) if (k.toLowerCase() === name) return h[k]; return ""; };

/**
 * The native HTTP layer keeps cookies from YouTube between requests and app launches and sends them back. A session that
 * carries those cookies no longer looks like a fresh anonymous client, and YouTube then answers LOGIN_REQUIRED to the
 * strict clients (VISIONOS, ANDROID_VR). The engine works without cookies (checked from a PC), so wipe the jar first.
 */
let cookieState = "not tried";
export const cookieStatus = () => cookieState;
export const clearCookies = async () => { await noCookies(); return cookieState; };
async function noCookies() {
  const c = window.Capacitor;
  try {
    const p = c?.Plugins?.CapacitorCookies ?? c?.registerPlugin?.("CapacitorCookies");
    if (!p?.clearAllCookies) { cookieState = "plugin missing"; return; }
    await p.clearAllCookies();
    cookieState = "cleared";
  } catch (e) { cookieState = "failed: " + String(e?.message || e).slice(0, 40); }
}
// HTTP header names are case-insensitive, but the native layer is happiest with the usual capitalisation
const canonical = (h) => Object.fromEntries(Object.entries(h).map(([k, v]) => [k.replace(/(^|-)([a-z])/g, (_, a, b) => a + b.toUpperCase()), v]));

async function toParts(input, init = {}) {
  const req = typeof Request !== "undefined" && input instanceof Request ? input : null;
  const url = req ? req.url : String(input);
  const method = (init.method || req?.method || "GET").toUpperCase();
  const headers = {};
  const src = init.headers || req?.headers;
  if (src) new Headers(src).forEach((v, k) => { headers[k.toLowerCase()] = v; });
  let body = init.body;
  if (body == null && req && method !== "GET" && method !== "HEAD") body = await req.clone().text();
  if (body != null && typeof body !== "string") body = await new Response(body).text();
  if (!headers["user-agent"]) headers["user-agent"] = MOBILE_UA;
  if (!headers["origin"]) headers["origin"] = new URL(url).origin;    // the Node build of the client sends this on every request, and that is the setup known to work
  if (WEB_CLIENT_IDS.has(headers["x-youtube-client-name"])) {            // web clients expect to look like a page on that site
    const o = new URL(url).origin;
    headers["origin"] = headers["origin"] || o;
    headers["referer"] = headers["referer"] || o + "/";
  }
  return { url, method, headers, body };
}

/** A fetch() the InnerTube client can use. env: { devBase, devToken } for the browser dev proxy. */
export function makeFetch(env = {}, opt = {}) {
  return async (input, init) => {
    const { url, method, headers, body } = await toParts(input, init);
    const http = nativeHttp();
    if (http) {
      const isJson = /json/i.test(headers["content-type"] || "");
      // `disableRedirects` makes the native layer use a brand-new URLSession, and so a brand-new connection, for this
      // request, instead of the shared one it keeps open for days. YouTube judges a long-lived connection by how much
      // it has done, and a connection that has done a lot gets "sign in to confirm you're not a bot" for the strict
      // clients. Redirects are followed by hand.
      let res, target = url, hops = 0;
      for (;;) {
        const r4 = opt.noV4 ? null : await viaV4({ url: target, method, headers, body: body ?? undefined, binary: false });
        if (r4) res = { status: r4.status, headers: r4.headers, data: r4.data };
        else {
          await noCookies();
          res = await http.request({
            url: target, method, headers: canonical(headers), responseType: "text", disableRedirects: true,
            data: body == null ? undefined : isJson ? JSON.parse(body) : body,
          });
        }
        const loc = hget(res.headers, "location");
        if (![301, 302, 303, 307, 308].includes(res.status) || !loc || ++hops > 4) break;
        target = new URL(loc, target).href;
      }
      const text = typeof res.data === "string" ? res.data : JSON.stringify(res.data ?? "");
      const status = res.status || 200;
      const noBody = status === 204 || status === 205 || status === 304;
      return new Response(noBody ? null : text, { status: status < 200 ? 200 : status, headers: res.headers || {} });
    }
    if (!env.devBase) throw new Error("No network path for the on-device engine (not running in the app, and no dev proxy).");
    const r = await fetch(`${env.devBase}/dev/fetch?url=${encodeURIComponent(url)}${env.devToken ? "&token=" + encodeURIComponent(env.devToken) : ""}`, {
      method: method === "GET" || method === "HEAD" ? "GET" : "POST",
      headers: { "x-fwd": JSON.stringify({ method, headers }) },
      body: method === "GET" || method === "HEAD" ? undefined : body,
    });
    return r;
  };
}

/** Download a byte range (used for offline saves): resolves to { blob, total, status }. */
export async function fetchBytes(url, start, end, env = {}) {
  const range = `bytes=${start}-${end}`;
  const http = nativeHttp();
  if (http) {
    const r4 = await viaV4({ url, method: "GET", headers: { Range: range, "User-Agent": MOBILE_UA }, binary: true });
    const res = r4 || await http.request({ url, method: "GET", headers: { Range: range, "User-Agent": MOBILE_UA }, responseType: "blob" });
    const bin = atob(res.data || "");
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    const cr = hget(res.headers, "content-range");
    return { blob: new Blob([bytes], { type: "audio/mp4" }), total: Number(cr.split("/")[1]) || 0, status: res.status };
  }
  if (!env.devBase) throw new Error("No network path for downloads.");
  const r = await fetch(`${env.devBase}/dev/fetch?url=${encodeURIComponent(url)}${env.devToken ? "&token=" + encodeURIComponent(env.devToken) : ""}`, {
    headers: { "x-fwd": JSON.stringify({ method: "GET", headers: { range, "user-agent": MOBILE_UA } }) },
  });
  const cr = r.headers.get("content-range") || "";
  return { blob: await r.blob(), total: Number(cr.split("/")[1]) || 0, status: r.status };
}
