// Loads the engine on demand (the 1.5 MB YouTube client is only fetched when the app runs on-device).
import { createEngine } from "./engine.js";
import { makeFetch, fetchBytes, cookieStatus, clearCookies, v4Status } from "./net.js";

let enginePromise = null;
let env = {};

/** The signed-in account's tokens (Settings → Account). Kept in local storage; never part of a backup. */
const AUTH_KEY = "ytauth";
const auth = {
  get: () => { try { return JSON.parse(localStorage.getItem(AUTH_KEY)) || null; } catch { return null; } },
  set: (c) => { try { if (c) localStorage.setItem(AUTH_KEY, JSON.stringify(c)); else localStorage.removeItem(AUTH_KEY); } catch {} },
};
export const isSignedIn = () => !!auth.get();
export const startSignIn = async () => (await getEngine()).startSignIn();
export const signOut = async () => (await getEngine()).signOut();

/** env.devBase / env.devToken: browser development only (see backend DEV_PROXY). */
export function configure(next) { env = { ...env, ...next }; enginePromise = null; }

export function getEngine() {
  enginePromise ??= (async () => {
    const lib = await import("../../vendor/youtubei.js");
    const probe = async (u, a = 0, b = 1) => { try { return (await fetchBytes(u, a, b, env)).status; } catch { return 0; } };
    return createEngine({ Innertube: lib.Innertube, fetch: makeFetch(env), probe, auth });
  })().catch((e) => { enginePromise = null; throw e; });
  return enginePromise;
}

export const handle = async (path) => (await getEngine()).handle(path);
export const resolveStream = async (id, quality, fresh) => (await getEngine()).resolveStream(id, quality, fresh);
/** Settings → About → Reset connection: wipe the cookie jar and start the YouTube client over with a brand-new session. */
export async function resetConnection() {
  const state = await clearCookies();
  enginePromise = null;
  return state;
}
export const downloadRange =(url, start, end) => fetchBytes(url, start, end, env);

/** What the phone's network looks like to YouTube (for Settings → About → Connection check). */
export async function diagnose() {
  const f = makeFetch(env);
  const ip = async (u) => { try { return (await (await f(u)).json()).ip || "none"; } catch { return "none"; } };
  const [v4, v6] = await Promise.all([ip("https://api.ipify.org?format=json"), ip("https://api6.ipify.org?format=json")]);
  let stream;
  try {
    const r = await (await getEngine()).resolveStream("9qnqYL0eNNI", "high", 2);
    stream = { client: r.client, ip: new URL(r.url).searchParams.get("ip") || "?", status: (await fetchBytes(r.url, 0, 1, env)).status };
  } catch (e) { stream = { error: String(e?.message || e).slice(0, 260) }; }
  // which address family iOS picks by itself for new connections (Capacitor's HTTP, not our IPv4 client): v4 or v6, per request
  const fam = [], plain = makeFetch(env, { noV4: true });
  for (let i = 0; i < 6; i++) {
    try { const ip = (await (await plain("https://api64.ipify.org?format=json")).json()).ip || ""; fam.push(ip.includes(":") ? "v6" : "v4"); } catch { fam.push("?"); }
  }
  let clients = [], info = null;
  try { clients = await (await getEngine()).probeClients("9qnqYL0eNNI"); } catch {}
  try { info = await (await getEngine()).sessionInfo(); } catch {}
  return { v4, v6, stream, clients, info, cookies: cookieStatus(), signedIn: isSignedIn(), family: fam.join(" "), v4client: v4Status() };
}
