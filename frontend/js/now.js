// Player UI: mini player + full-screen player (phone), bottom bar + right panel (desktop),
// and the Up next / Lyrics / Related content they share.
import { api, art, fmtTime } from "./api.js";
import * as store from "./store.js";
import * as P from "./player.js";
import * as S from "./settings.js";
import { ic, logo } from "./icons.js";
import { $, $$, esc, toast, reg, sub, trackRow, trackRows, applyAccent, tintFrom } from "./ui.js";
import { toggleLike, saveOffline, isSaving, openMenu, openExport } from "./sheets.js";
import { navigate } from "./nav.js";

export const actions = {};
const mq = matchMedia("(min-width:900px)");
const np = $("#np");
let npTab = "queue", sheetOpen = false, panelOpen = store.kv.get("panelOpen", true);
let dragging = false, tintFor = null, activeLine = -1;

const SLEEP_LABELS = ["Off", "15m", "30m", "60m"];

/* ---------- one-time setup ---------- */
export function init() {
  const set = (id, html) => { const el = $(id); if (el) el.innerHTML = html; };
  set("#brand-logo", logo(30)); set("#dsearch-ic", ic("search", 20)); set("#dtop-gear", ic("gear", 22));
  set("#np-close", ic("chevDown", 26)); set("#np-menu", ic("dots", 22)); set("#np-sheet-x", ic("close", 22));
  set("#b-prev", ic("prev", 30)); set("#b-next", ic("next", 30));
  set("#bar-prev", ic("prev", 24)); set("#bar-next", ic("next", 24)); set("#bar-menu", ic("dots", 22));
  set("#bar-panel", ic("panel", 22));
  set("#p-air", ic("cast", 18)); set("#p-dl", ic("download", 16)); set("#p-files", ic("file", 16) + "Files");
  $("#np-dislike").classList.add("rot180"); $("#bar-dislike").classList.add("rot180");
  if (window.WebKitPlaybackTargetAvailabilityEvent) $("#p-air").hidden = false;
  const vol = store.kv.get("volume", 100); $("#bar-vol").value = vol; P.audio.volume = vol / 100;

  P.bus.addEventListener("track", (e) => paintTrack(e.detail));
  P.bus.addEventListener("state", paintState);
  P.bus.addEventListener("toast", (e) => toast(e.detail, 7000));
  P.bus.addEventListener("mode", paintMode);
  P.bus.addEventListener("time", paintTime);
  P.bus.addEventListener("queue", () => { if (npTab === "queue") drawTab(); });
  document.addEventListener("marks", paintMarks);
  document.addEventListener("close-np", closeNP);
  document.addEventListener("dl-progress", (e) => {
    const { id, p } = e.detail, b = $("#p-dl");
    if (P.current()?.videoId !== id) return;
    b.classList.toggle("busy", p >= 0);
    b.innerHTML = ic("download", 16) + (p >= 0 && p < 1 ? `${Math.round(p * 100)}%` : "");
  });
  mq.addEventListener("change", () => { paintTrack(P.current()); drawTab(); });

  for (const id of ["#seek", "#bar-seek"]) {
    const el = $(id);
    el.addEventListener("input", () => { dragging = true; const f = el.value / 1000; el.style.setProperty("--p", f * 100 + "%"); if (id === "#seek") $("#t-cur").textContent = fmtTime(f * P.duration()); });
    el.addEventListener("change", () => { P.seek((el.value / 1000) * P.duration()); dragging = false; });
  }
  $("#bar-vol").addEventListener("input", (e) => { const v = Number(e.target.value); P.audio.volume = v / 100; P.audio.muted = false; e.target.style.setProperty("--p", v + "%"); store.kv.set("volume", v); paintMute(); });
  $("#bar-vol").style.setProperty("--p", vol + "%");

  // swipe the full-screen player down to close
  let sy = null;
  np.addEventListener("touchstart", (e) => { if (e.target.closest("input,.np-sheet")) return; sy = e.touches[0].clientY; }, { passive: true });
  np.addEventListener("touchend", (e) => { if (sy !== null && e.changedTouches[0].clientY - sy > 110) closeNP(); sy = null; }, { passive: true });

  paintState(); paintMode(); paintTrack(null); paintMute();
}

export function openNP() { if (mq.matches) return; np.classList.add("open"); np.setAttribute("aria-hidden", "false"); }
export function closeNP() { np.classList.remove("open"); np.setAttribute("aria-hidden", "true"); closeNpSheet(); }
function closeNpSheet() { sheetOpen = false; $("#np-sheet").hidden = true; }

/** Re-apply the accent (after a settings change) and re-tint from the current artwork if needed. */
export function refreshAccent() {
  applyAccent();
  const t = P.current();
  if (S.get().accent === "art" && t) { tintFor = t.videoId; tintFrom(art(t.thumbnail, 120)); }
}

/* ---------- painting ---------- */
function paintTrack(t) {
  const has = !!t;
  $("#mini").hidden = !has;
  $("#bar").hidden = !has;
  $("#panel").hidden = !has || !panelOpen;
  document.body.classList.toggle("has-track", has);
  if (!has) return;
  const artist = sub(t), album = t.album || "";
  $("#mini-art").src = art(t.thumbnail, 120);
  $("#mini-title").textContent = t.title; $("#mini-artist").textContent = artist;
  $("#np-art").src = art(t.thumbnail, 600);
  $("#np-bg").style.backgroundImage = `url("${art(t.thumbnail, 600)}")`;
  $("#np-title").textContent = t.title;
  $("#np-sub").innerHTML = `<span class="${t.artistIds?.[0] ? "lnk" : ""}" data-act="np-artist">${esc(artist)}</span>${album ? " · " + esc(album) : ""}`;
  $("#bar-art").src = art(t.thumbnail, 120);
  $("#bar-title").textContent = t.title; $("#bar-sub").textContent = [artist, album].filter(Boolean).join(" · ");
  $("#panel-img").src = art(t.thumbnail, 400);
  document.title = `${t.title} · YT Music`;
  activeLine = -1;
  paintMarks();
  drawTab();
  if (S.get().accent === "art" && tintFor !== t.videoId) { tintFor = t.videoId; tintFrom(art(t.thumbnail, 120)); }
}
function paintState() {
  const playing = !P.audio.paused;
  const play = ic(playing ? "pause" : "play", 26), big = ic(playing ? "pause" : "play", 32);
  $("#mini-play").innerHTML = ic(playing ? "pause" : "play", 26); $("#b-play").innerHTML = big; $("#bar-play").innerHTML = play;
  for (const id of ["#mini-play", "#b-play", "#bar-play"]) $(id).setAttribute("aria-label", playing ? "Pause" : "Play");
}
function paintMode() {
  const { shuffle, repeat } = P.state, ri = repeat === "one" ? "repeat1" : "repeat";
  for (const [id, on, icon, size] of [["#b-shuffle", shuffle, "shuffle", 24], ["#bar-shuffle", shuffle, "shuffle", 22], ["#b-repeat", repeat !== "off", ri, 24], ["#bar-repeat", repeat !== "off", ri, 22]]) {
    const el = $(id); el.classList.toggle("on", on); el.innerHTML = ic(icon, size); el.setAttribute("aria-pressed", on);
  }
  $("#b-repeat").setAttribute("aria-label", ["Repeat off", "Repeat all", "Repeat one"][["off", "all", "one"].indexOf(repeat)]);
  const sp = P.SPEEDS[P.extras.speedIdx], sl = P.extras.sleepIdx;
  $("#p-speed").innerHTML = ic("speed", 16, { sw: 2 }) + (sp === 1 ? "1×" : sp + "×"); $("#p-speed").classList.toggle("on", sp !== 1);
  $("#p-sleep").innerHTML = ic("clock", 16, { sw: 2 }) + SLEEP_LABELS[sl]; $("#p-sleep").classList.toggle("on", sl > 0);
  $("#p-speed").setAttribute("aria-label", `Playback speed ${sp}×`); $("#p-sleep").setAttribute("aria-label", `Sleep timer ${SLEEP_LABELS[sl]}`);
  $("#bar-panel").classList.toggle("on", panelOpen);
}
function paintMute() {
  const m = P.audio.muted || P.audio.volume === 0;
  $("#bar-mute").innerHTML = ic(m ? "mute" : "vol", 22); $("#bar-mute").setAttribute("aria-label", m ? "Unmute" : "Mute");
}
function paintTime() {
  const a = P.audio, d = P.duration(), c = a.currentTime || 0, f = d ? c / d : 0;
  $("#mini-prog").style.width = f * 100 + "%";
  if (!dragging) {
    for (const id of ["#seek", "#bar-seek"]) { const el = $(id); el.value = Math.round(f * 1000); el.style.setProperty("--p", f * 100 + "%"); }
    $("#t-cur").textContent = fmtTime(c); $("#bar-cur").textContent = fmtTime(c);
  }
  $("#t-dur").textContent = fmtTime(d); $("#bar-dur").textContent = fmtTime(d);
  if (npTab === "lyrics") syncLyrics(c);
}
function paintMarks() {
  const t = P.current();
  const liked = !!t && store.isLiked(t.videoId), dis = !!t && store.isDisliked(t.videoId), saved = !!t && store.downloadedIds.has(t.videoId);
  for (const id of ["#mini-like", "#np-like", "#bar-like"]) { const el = $(id); el.classList.toggle("on", liked); el.innerHTML = ic("thumb", 22, { fill: liked }); el.setAttribute("aria-pressed", liked); }
  for (const id of ["#np-dislike", "#bar-dislike"]) { const el = $(id); el.classList.toggle("on", dis); el.innerHTML = ic("thumb", 22, { fill: dis }); el.setAttribute("aria-pressed", dis); }
  const dl = $("#p-dl");
  if (!isSaving(t?.videoId)) { dl.classList.toggle("on", saved); dl.innerHTML = saved ? ic("check", 16, { sw: 2.4 }) : ic("download", 16); dl.setAttribute("aria-label", saved ? "Saved offline" : "Save offline"); }
  $$(".qrow[data-id], .tcard[data-id]").forEach((el) => {
    el.classList.toggle("now", t?.videoId === el.dataset.id);
    el.classList.toggle("saved", store.downloadedIds.has(el.dataset.id));
  });
}

/* ---------- queue / lyrics / related ---------- */
const lyricsCache = {}, relCache = {};
function tabHtml(tab) {
  if (tab === "lyrics") return lyricsHtml();
  if (tab === "related") return relatedHtml();
  const q = P.state.queue, on = S.get().autoplay;
  return `<div class="autoplay-row"><div><b>Autoplay</b><span>Keep playing similar songs</span></div><button class="switch${on ? " on" : ""}" role="switch" aria-checked="${on}" aria-label="Autoplay" data-act="toggle-autoplay"><i></i></button></div>` +
    (q.length ? q.map((t, i) => trackRow(t, i, "queue", {
      size: "md", eq: true, hl: true, act: "qgo",
      right: `<span style="display:flex;align-items:center;gap:2px"><span class="dur">${esc(t.duration || "")}</span>${i === P.state.idx ? '<span style="width:32px"></span>' : `<button class="ib dim" style="width:32px;height:32px" data-act="qrm" data-i="${i}" aria-label="Remove from queue">${ic("close", 16)}</button>`}</span>`,
    })).join("") : '<div class="noly"><b>Nothing queued</b><span>Play a song and the next ones show up here.</span></div>');
}
function lyricsHtml() {
  const t = P.current(); if (!t) return "";
  const c = lyricsCache[t.videoId];
  if (!c) { fetchLyrics(t); return '<div class="noly"><span>Looking for lyrics…</span></div>'; }
  if (c.state === "loading") return '<div class="noly"><span>Looking for lyrics…</span></div>';
  if (c.state === "none") return '<div class="noly"><b>No lyrics for this song</b><span>Lyrics show here and follow the song line by line when they are available.</span></div>';
  const d = c.data, src = d.source ? `<div class="lyr-src">${esc(d.source)}</div>` : "";
  if (d.lines?.length) return `<div class="lyr timed">${d.lines.map((l, i) => `<div data-i="${i}" data-t="${l.start}" data-act="lyr-seek">${esc(l.text)}</div>`).join("")}</div>${src}`;
  return `<div class="lyr plain">${(d.lyrics || "").split("\n").filter((l) => l.trim()).map((l) => `<div>${esc(l)}</div>`).join("")}</div>${src}`;
}
async function fetchLyrics(t) {
  lyricsCache[t.videoId] = { state: "loading" };
  const m = /^(?:(\d+):)?(\d+):(\d{2})$/.exec(String(t.duration || ""));            // "3:45" → seconds, for matching the fallback source
  const dur = P.current()?.videoId === t.videoId && isFinite(P.audio.duration) && P.audio.duration ? P.audio.duration : m ? (Number(m[1] || 0) * 3600 + Number(m[2]) * 60 + Number(m[3])) : Number(t.duration) || 0;
  const qs = `?title=${encodeURIComponent(t.title || "")}&artist=${encodeURIComponent((t.artists || [])[0] || "")}&dur=${Math.round(dur) || ""}`;
  try { lyricsCache[t.videoId] = { state: "ok", data: await api(`/api/lyrics/${t.videoId}${qs}`) }; }
  catch { lyricsCache[t.videoId] = { state: "none" }; }
  if (P.current()?.videoId === t.videoId && npTab === "lyrics") drawTab();
}
function syncLyrics(time) {
  const t = P.current(), c = t && lyricsCache[t.videoId];
  const lines = c?.state === "ok" && c.data.lines; if (!lines) return;
  let idx = -1; for (let i = 0; i < lines.length; i++) { if (lines[i].start <= time + 0.15) idx = i; else break; }
  if (idx === activeLine) return;
  activeLine = idx;
  $$(".lyr.timed").forEach((box) => {
    box.querySelectorAll("div.act").forEach((d) => d.classList.remove("act"));
    const el = box.children[idx]; if (!el) return;
    el.classList.add("act");
    if (box.offsetParent) centerIn(box.closest(".np-sheet-body, .pbody"), el, true);
  });
}
function relatedHtml() {
  const t = P.current(); if (!t) return "";
  const c = relCache[t.videoId];
  if (!c) { fetchRelated(t); return '<div class="rel-h">You might also like</div>' + '<div class="sk row"></div>'.repeat(4); }
  const list = c.list;
  return `<div class="rel-h">You might also like</div>` + (list.length ? list.map((x, i) => trackRow(x, i, reg("related", list), { size: "rel", cv: "lg", right: "", sub: [sub(x), x.album].filter(Boolean).join(" · ") })).join("") : '<div class="noly"><span>No suggestions right now.</span></div>');
}
async function fetchRelated(t) {
  relCache[t.videoId] = { list: [], loading: true };
  try { relCache[t.videoId] = { list: (await api(`/api/radio/${t.videoId}`)).filter((x) => x.videoId !== t.videoId).slice(0, 14) }; }
  catch { relCache[t.videoId] = { list: [] }; }
  if (P.current()?.videoId === t.videoId && npTab === "related") drawTab();
}
/** Scroll only the list's own container so the row sits mid-view (scrollIntoView would also scroll the overlay). */
function centerIn(box, el, smooth) {
  if (!box || !el) return;
  box.scrollTo({ top: el.offsetTop - box.clientHeight / 2 + el.offsetHeight / 2, behavior: smooth ? "smooth" : "auto" });
}
function syncTabs() {
  $$("[data-tab-name]").forEach((b) => { const on = b.dataset.tabName === npTab; b.classList.toggle("on", on); b.setAttribute("aria-selected", on); });
}
function drawTab() {
  const targets = [];
  if (sheetOpen) targets.push($("#np-sheet-body"));
  if (mq.matches && !$("#panel").hidden) targets.push($("#panel-body"));
  if (!targets.length) return;
  syncTabs();
  const html = tabHtml(npTab);
  targets.forEach((el) => { el.innerHTML = html; });
  if (npTab === "queue") targets.forEach((el) => centerIn(el, el.querySelector(".cur"), false));
  if (npTab === "lyrics") { activeLine = -1; syncLyrics(P.audio.currentTime || 0); }
}
function showTab(name) {
  npTab = name;
  if (mq.matches) { panelOpen = true; store.kv.set("panelOpen", true); $("#panel").hidden = !P.current(); paintMode(); }
  else { sheetOpen = true; $("#np-sheet").hidden = false; }
  drawTab();
}

/* ---------- actions ---------- */
actions["np-open"] = openNP;
actions["np-close"] = closeNP;
actions["sheet-np-close"] = closeNpSheet;
actions["tab-queue"] = () => showTab("queue");
actions["tab-lyrics"] = () => showTab("lyrics");
actions["tab-related"] = () => showTab("related");
actions["toggle-panel"] = () => { panelOpen = !panelOpen; store.kv.set("panelOpen", panelOpen); $("#panel").hidden = !P.current() || !panelOpen; paintMode(); if (panelOpen) drawTab(); };
actions["toggle-autoplay"] = () => { S.set({ autoplay: !S.get().autoplay }); drawTab(); };
actions["qgo"] = (el) => P.go(Number(el.dataset.i));
actions["qrm"] = (el) => P.removeAt(Number(el.dataset.i));
actions["lyr-seek"] = (el) => { const t = Number(el.dataset.t); if (isFinite(t)) P.seek(t); };
actions["np-artist"] = () => { const id = P.current()?.artistIds?.[0]; if (id) { closeNP(); navigate({ name: "collection", kind: "artist", id }); } };
actions["menu-now"] = () => { const t = P.current(); if (t) openMenu(t); };
actions["like-now"] = () => { const t = P.current(); if (t) toggleLike(t); };
actions["dislike-now"] = () => {
  const t = P.current(); if (!t) return;
  const now = P.dislike(t);
  toast(now ? "Got it. We'll play less like this" : "Dislike removed"); paintMarks();
};
actions["dl-now"] = () => { const t = P.current(); if (!t) return; if (store.downloadedIds.has(t.videoId)) toast("Already saved for offline"); else saveOffline(t); };
actions["export-now"] = () => { const t = P.current(); if (t) openExport(t); };
actions["sleep"] = () => { P.cycleSleep(); toast(P.extras.sleepIdx ? `Sleep timer: ${SLEEP_LABELS[P.extras.sleepIdx]}` : "Sleep timer off"); };
actions["speed"] = () => P.cycleSpeed();
actions["airplay"] = () => { try { P.audio.webkitShowPlaybackTargetPicker(); } catch { toast("AirPlay isn't available here"); } };
actions["mute"] = () => { P.audio.muted = !P.audio.muted; paintMute(); };
