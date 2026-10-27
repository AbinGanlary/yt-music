// Service worker: app shell works offline; API answers fall back to the last good copy; art is cached.
// Audio (/stream) is never cached here: saved songs live in IndexedDB.
const VERSION = "v31";
const SHELL = `grooves-shell-${VERSION}`, DATA = `grooves-data-${VERSION}`, IMG = `grooves-img-${VERSION}`;
const SHELL_FILES = [
  "/", "/styles.css", "/manifest.webmanifest",
  "/js/app.js", "/js/api.js", "/js/store.js", "/js/player.js", "/js/settings.js",
  "/js/ui.js", "/js/nav.js", "/js/views.js", "/js/sheets.js", "/js/now.js", "/js/mix.js", "/js/stats.js", "/js/backup.js", "/js/account.js", "/js/icons.js",
  "/fonts/bricolage.woff2", "/fonts/dmsans.woff2",
  "/icons/icon-192.png", "/icons/icon-512.png", "/icons/apple-touch-icon.png",
];

self.addEventListener("install", (e) => {
  // cache: "reload" skips the HTTP cache so a new version never precaches stale copies
  e.waitUntil(
    caches.open(SHELL)
      .then((c) => c.addAll(SHELL_FILES.map((u) => new Request(u, { cache: "reload" }))))
      .then(() => self.skipWaiting())
  );
});
self.addEventListener("activate", (e) => {
  e.waitUntil((async () => {
    const stale = (await caches.keys()).filter((k) => ![SHELL, DATA, IMG].includes(k));
    await Promise.all(stale.map((k) => caches.delete(k)));
    await self.clients.claim();
    // An update just took over: reload open pages once so they run the new code instead of the old.
    if (stale.length) for (const c of await self.clients.matchAll({ type: "window" })) c.navigate(c.url).catch(() => {});
  })());
});

async function networkFirst(req, name, ms = 4000) {
  const cache = await caches.open(name);
  try {
    const ctl = new AbortController();
    const t = setTimeout(() => ctl.abort(), ms);
    const r = await fetch(req, { signal: ctl.signal, cache: "no-cache" });   // never trust a stale HTTP-cached copy
    clearTimeout(t);
    if (r.ok) cache.put(req, r.clone());
    return r;
  } catch {
    const hit = await cache.match(req, { ignoreVary: true });
    if (hit) return hit;
    throw new Error("offline");
  }
}
async function cacheFirst(req, name, max = 400) {
  const cache = await caches.open(name);
  const hit = await cache.match(req);
  if (hit) return hit;
  const r = await fetch(req);
  if (r.ok) {
    cache.put(req, r.clone());
    cache.keys().then((ks) => ks.length > max && cache.delete(ks[0]));   // crude LRU: drop the oldest
  }
  return r;
}

self.addEventListener("fetch", (e) => {
  const req = e.request, url = new URL(req.url);
  if (req.method !== "GET" || url.origin !== location.origin) return;
  if (url.pathname.startsWith("/stream/")) return;                         // let audio go straight to the network
  if (url.pathname === "/api/img") return void e.respondWith(cacheFirst(req, IMG));
  if (url.pathname.startsWith("/api/")) return void e.respondWith(networkFirst(req, DATA));
  // shell: network first so edits show up immediately, cache when offline
  e.respondWith(networkFirst(req, SHELL, 2500).catch(() => caches.match("/")));
});
