// Shared UI helpers: DOM shortcuts, toast, track/collection builders, accent colour.
import { art } from "./api.js";
import * as store from "./store.js";
import * as P from "./player.js";
import * as S from "./settings.js";
import { ic } from "./icons.js";

export const APP_NAME = "YT Music";
export const APP_VERSION = "31";

export const $ = (s, r = document) => r.querySelector(s);
export const $$ = (s, r = document) => [...r.querySelectorAll(s)];
export const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

let toastT;
export function toast(msg, ms = 2400) {
  const el = $("#toast");
  el.textContent = msg; el.classList.add("show");
  clearTimeout(toastT); toastT = setTimeout(() => el.classList.remove("show"), ms);
}

/* lists of tracks keyed by name, so a tapped row can play its whole list */
export const lists = {};
export const reg = (key, arr) => (lists[key] = arr, key);
export const byId = (id) => Object.values(lists).flat().find((t) => t.videoId === id) || P.state.queue.find((t) => t.videoId === id) || store.getLikes().find((t) => t.videoId === id);
export const artistReg = new Map();           // browseId → artist item, for the taste picker

export const sub = (t) => (t.artists || []).join(", ");
export const hue = (s) => { let h = 0; for (const c of String(s)) h = (h * 31 + c.charCodeAt(0)) % 360; return h; };
export const gradient = (s) => { const h = hue(s); return `linear-gradient(135deg,hsl(${h} 45% 34%),hsl(${(h + 40) % 360} 55% 18%))`; };

/** A cover image, or a gradient tile with an initial when there's no artwork. */
export function cover(thumb, cls = "", fallback = "", size = 120) {
  if (thumb) return `<img class="cv ${cls}" loading="lazy" decoding="async" src="${art(thumb, size)}" alt="">`;
  return `<span class="cv mosaic ${cls}" style="background:${gradient(fallback)}">${esc((fallback || "♪").trim().charAt(0).toUpperCase())}</span>`;
}

export const eqMask = '<span class="eqmask"><span class="eq"><i></i><i></i><i></i></span></span>';

/** One song row. o: {size:"md"|"xl"|"lg", eq, hl, right, ctx, sub} */
export function trackRow(t, i, key, o = {}) {
  const isCur = P.current()?.videoId === t.videoId;
  const cls = ["qrow", o.size || "", isCur ? "now" : "", o.hl && isCur ? "cur" : "", store.downloadedIds.has(t.videoId) ? "saved" : ""].filter(Boolean).join(" ");
  const img = `<img class="cv ${o.cv || ""}" loading="lazy" decoding="async" src="${art(t.thumbnail, 120)}" alt="">`;
  const cv = o.eq ? `<span class="cvwrap">${img}${isCur ? eqMask : ""}</span>` : img;
  const ctx = o.ctx ? ` data-ctx="${esc(o.ctx)}"` : "";
  return `<div class="${cls}" role="button" tabindex="0" data-act="${o.act || "play"}" data-key="${key}" data-i="${i}" data-id="${t.videoId}"${ctx} aria-label="Play ${esc(t.title)} by ${esc(sub(t))}">
    ${cv}<span class="qmeta"><b>${esc(t.title)}</b><span>${esc(o.sub ?? sub(t))}</span></span>
    ${o.right ?? `<button class="dots" data-act="menu" data-id="${t.videoId}"${ctx} aria-label="More actions">${ic("dots", 20)}</button>`}
  </div>`;
}
export const trackRows = (arr, key, o) => arr.map((t, i) => trackRow(t, i, key, o)).join("");

export const trackCard = (t, i, key, n) => `
  <button class="tcard${P.current()?.videoId === t.videoId ? " now" : ""}" data-act="play" data-key="${key}" data-i="${i}" data-id="${t.videoId}" aria-label="Play ${esc(t.title)} by ${esc(sub(t))}">
    <img class="cv" loading="lazy" decoding="async" src="${art(t.thumbnail, 300)}" alt="">
    ${n ? `<i class="n">${n}</i>` : ""}
    <span class="qmeta"><b>${esc(t.title)}</b><span>${esc(sub(t))}</span></span>
  </button>`;
/** album / playlist / artist card: opens a page instead of playing */
export const collCard = (c, grid) => `
  <button class="tcard${c.kind === "artist" ? " round" : ""}${grid ? " grid" : ""}" data-act="open" data-kind="${c.kind}" data-id="${esc(c.id)}" aria-label="Open ${esc(c.title)}">
    <img class="cv" loading="lazy" decoding="async" src="${art(c.thumbnail, 300)}" alt="">
    <span class="qmeta"><b>${esc(c.title)}</b><span>${esc(c.subtitle || "")}</span></span>
  </button>`;
export const shelf = (html, cls = "") => `<div class="hs ${cls}">${html}</div>`;
export const trackShelf = (arr, key, numbered, cls) => shelf(arr.map((t, i) => trackCard(t, i, key, numbered ? i + 1 : 0)).join(""), cls);
export const collShelf = (arr) => shelf(arr.map((c) => collCard(c)).join(""));
export const skShelf = shelf('<div class="sk card"></div>'.repeat(5));
export const skRows = '<div class="sk row"></div>'.repeat(5);
export const fail = (what, act) => `<p class="note">Couldn't load ${what}. <button class="btn ghost sm" data-act="${act}">Try again</button></p>`;
export const empty = (title, text) => `<div class="empty"><b>${esc(title)}</b><span>${esc(text)}</span></div>`;

/* ---------- accent colour ---------- */
let artAccent = null;
export function applyAccent(fromArt) {
  if (fromArt) artAccent = fromArt;
  const a = S.get().accent;
  document.documentElement.style.setProperty("--accent", a === "art" ? artAccent || "#ff6a3d" : a);
}

/** The two layout styles (Settings → Appearance) are plain attributes on <body>; the CSS does the rest. */
export function applyStyle() {
  const s = S.get();
  document.body.dataset.nav = s.uiNav === "classic" ? "classic" : "glass";
  document.body.dataset.np = s.uiNp === "classic" ? "classic" : "blur";
}

/** Pull a vivid colour out of the artwork (used when the accent is set to "Artwork"). */
export function tintFrom(src) {
  const img = new Image();
  img.crossOrigin = "anonymous";
  img.onload = () => {
    try {
      const c = document.createElement("canvas"); c.width = c.height = 24;
      const g = c.getContext("2d", { willReadFrequently: true });
      g.drawImage(img, 0, 0, 24, 24);
      const d = g.getImageData(0, 0, 24, 24).data;
      let best = null, bs = -1;
      for (let i = 0; i < d.length; i += 4) {
        const [r, gg, b] = [d[i] / 255, d[i + 1] / 255, d[i + 2] / 255];
        const mx = Math.max(r, gg, b), mn = Math.min(r, gg, b), l = (mx + mn) / 2;
        const s = mx === mn ? 0 : (mx - mn) / (1 - Math.abs(2 * l - 1));
        const score = s * (1 - Math.abs(l - 0.5));
        if (score > bs) { bs = score; best = [r, gg, b]; }
      }
      if (!best || bs < 0.12) return;
      const [r, gg, b] = best, mx = Math.max(r, gg, b), mn = Math.min(r, gg, b);
      let h = 0;
      if (mx !== mn) h = mx === r ? ((gg - b) / (mx - mn)) % 6 : mx === gg ? (b - r) / (mx - mn) + 2 : (r - gg) / (mx - mn) + 4;
      h = Math.round(((h * 60) + 360) % 360);
      applyAccent(`hsl(${h} 82% 60%)`);
    } catch {}
  };
  img.src = src;
}
