// A headless page that runs the same YouTube engine as the web app, so the SwiftUI app can ask it for search results and stream addresses.
// Network requests go back to Swift (the app's IPv4-only client) through the "net" message handler.
const bridge = (opts) => window.webkit.messageHandlers.net.postMessage(opts);
window.Capacitor = {
  isNativePlatform: () => true,
  Plugins: {
    Ipv4Http: { request: bridge },
    // The engine only takes the native path when these exist. It always tries Ipv4Http first, so these are never really used.
    CapacitorHttp: { request: async () => { throw new Error("CapacitorHttp is not available in this app"); } },
    CapacitorCookies: { clearAllCookies: async () => {} },
  },
  registerPlugin(name) { return this.Plugins[name]; },
};

const ready = import("./js/engine/index.js");
window.host = {
  api: async (path) => JSON.stringify(await (await ready).handle(path)),
  stream: async (id, fresh, quality) => JSON.stringify(await (await ready).resolveStream(id, quality || "high", fresh || false)),
  diagnose: async () => JSON.stringify(await (await ready).diagnose()),
  resetConnection: async () => String(await (await ready).resetConnection()),
  signedIn: async () => String((await ready).isSignedIn()),
  // Google's TV device sign-in: signIn() returns the code to type at google.com/device, signInDone() waits until it is approved.
  signIn: async () => {
    const s = await (await ready).startSignIn();
    pendingSignIn = s.done;
    return JSON.stringify({ url: s.url, code: s.code, expiresIn: s.expiresIn });
  },
  signInDone: async () => {
    await pendingSignIn;
    return JSON.stringify(await (await ready).handle("/api/account"));
  },
  signOut: async () => { await (await ready).signOut(); return "ok"; },
};
let pendingSignIn = null;
