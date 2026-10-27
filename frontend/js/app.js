import { isNative, getBase, getSource } from "./api.js";
import * as store from "./store.js";
import * as P from "./player.js";
import * as S from "./settings.js";
import { $, toast, lists, byId, applyAccent, applyStyle } from "./ui.js";
import { show, navigate, back, setTab } from "./nav.js";
import * as views from "./views.js";
import * as sheets from "./sheets.js";
import * as now from "./now.js";
import * as mix from "./mix.js";
import * as stats from "./stats.js";
import * as backup from "./backup.js";
import * as account from "./account.js";

/** Drop the cached app files and reload. Saved songs (IndexedDB) and settings are untouched. */
async function updateApp() {
  toast("Updating…");
  try {
    for (const r of (await navigator.serviceWorker?.getRegistrations?.()) || []) await r.update().catch(() => {});
    for (const k of await caches.keys()) if (k.includes("shell") || k.includes("data")) await caches.delete(k);
  } catch {}
  location.reload();
}

const modules = [views.actions, sheets.actions, now.actions, mix.actions, stats.actions, backup.actions, account.actions];

document.addEventListener("click", (e) => {
  const el = e.target.closest("[data-act]"); if (!el) return;
  const act = el.dataset.act;
  switch (act) {
    case "play": {
      const arr = lists[el.dataset.key]; if (!arr) return;
      P.playList(arr, Number(el.dataset.i || 0)); return;
    }
    case "shuffle-list": {
      const arr = lists[el.dataset.key]; if (!arr) return;
      if (!P.state.shuffle) P.toggleShuffle();
      P.playList(arr.slice().sort(() => Math.random() - 0.5), 0); return;
    }
    case "artist-radio": { P.startRadio(byId(el.dataset.id) || { videoId: el.dataset.id, title: "Radio", artists: [] }); toast("Starting radio"); return; }
    case "toggle": P.toggle(); return;
    case "next": P.next(); return;
    case "prev": P.prev(); return;
    case "shuffle": P.toggleShuffle(); return;
    case "repeat": P.cycleRepeat(); return;
    case "back": back(); return;
    case "tab": now.closeNP(); setTab(el.dataset.tab); return;
    case "open": now.closeNP(); navigate({ name: "collection", kind: el.dataset.kind, id: el.dataset.id }); return;
    case "menu": { const t = byId(el.dataset.id); if (t) sheets.openMenu(t, el.dataset.ctx || ""); return; }
    case "app-update": updateApp(); return;
  }
  for (const m of modules) if (m[act]) { m[act](el, e); return; }
});

// role="button" rows act like buttons from the keyboard
document.addEventListener("keydown", (e) => {
  if ((e.key === "Enter" || e.key === " ") && e.target.matches?.('[role="button"]')) { e.preventDefault(); e.target.click(); return; }
  if (e.key === "Enter" && e.target.id === "pl-name") { e.preventDefault(); document.querySelector("#sheet-body .btn[data-act^=pl-]")?.click(); return; }
  if (/input|textarea/i.test(e.target.tagName)) return;
  if (e.code === "Space") { e.preventDefault(); P.toggle(); }
  else if (e.key === "ArrowRight" && e.shiftKey) P.next();
  else if (e.key === "ArrowLeft" && e.shiftKey) P.prev();
  else if (e.key === "Escape") { sheets.closeSheet(); now.closeNP(); }
});

document.addEventListener("input", (e) => {
  if (e.target.id === "loc-q") sheets.drawLocations(e.target.value);
  if (e.target.id === "rt-range") sheets.rtRange(e.target.value);
  if (e.target.id === "fit-range") {
    const v = Number(e.target.value);
    S.set({ bottomNudge: v });
    e.target.style.setProperty("--p", v + "%");
    $("#fit-val").textContent = v ? `+${v} px` : "Auto";
  }
});
document.addEventListener("submit", (e) => {
  if (e.target.id === "dsearch") { e.preventDefault(); views.doSearch($("#dq").value); }
});

S.bus.addEventListener("change", (e) => { if ("accent" in e.detail) now.refreshAccent(); if ("uiNav" in e.detail || "uiNp" in e.detail) applyStyle(); });
document.addEventListener("need-connection", (e) => { if ($("#sheet").hidden) sheets.openConnection(e.detail?.reason); });
document.addEventListener("connected", () => { setTab("home"); });
let limitedAt = 0;
document.addEventListener("limited-stream", () => {          // YouTube only served a short-range address for this song
  if (Date.now() - limitedAt < 120000) return;
  limitedAt = Date.now();
  toast("Limited stream: this song may stop after about a minute. Settings → About → Connection check shows why.", 8000);
});

/* ---------- screen fit ----------
   The app is `position:fixed` to the window, so it adapts to any device by itself. Some iOS home-screen apps leave an empty
   strip under the tab bar that the page can't see; "Screen fit" in Settings lets you extend the app downward by a few px. */
function fitViewport() {
  const root = document.documentElement, extra = S.get().bottomNudge || 0;
  if (extra > 0) root.style.setProperty("--app-h", window.innerHeight + extra + "px");
  else root.style.removeProperty("--app-h");
}
fitViewport();
["resize", "orientationchange", "pageshow"].forEach((e) => window.addEventListener(e, () => setTimeout(fitViewport, 50)));
document.addEventListener("visibilitychange", () => { if (!document.hidden) setTimeout(fitViewport, 50); });
S.bus.addEventListener("change", (e) => { if ("bottomNudge" in e.detail) fitViewport(); });

/* ---------- boot ---------- */
applyAccent();
applyStyle();
now.init();
views.buildChrome();
store.initDownloads().finally(() => {
  show({ name: "home" });
  P.restore();
});

if (isNative()) {
  document.body.classList.add("native");
  const sb = window.Capacitor?.Plugins?.StatusBar;       // light status-bar text on the dark UI, drawn over the page
  try { sb?.setStyle({ style: "DARK" }); sb?.setOverlaysWebView({ overlay: true }); } catch {}
  if (getSource() === "server" && !getBase()) setTimeout(() => sheets.openConnection(), 400);   // server mode without an address: ask for it
} else if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("/sw.js").catch(() => {});
}
