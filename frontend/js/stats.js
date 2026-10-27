// Analytics tab: what you listen to, worked out from the play log the player keeps on this device (store.logPlay).
import { art } from "./api.js";
import * as store from "./store.js";
import { ic } from "./icons.js";
import { esc, toast, reg, trackRow, empty } from "./ui.js";
import { register, page, rerender } from "./nav.js";
import { openSheet, closeSheet } from "./sheets.js";

export const actions = {};

const RANGES = [["Week", 7], ["Month", 30], ["Year", 365], ["All", 0]];
let range = 1;
const DAY = 86400;
const gear = `<button class="ib" data-act="open-settings" aria-label="Settings">${ic("gear", 22)}</button>`;

const fmtDur = (s) => { const h = Math.floor(s / 3600), m = Math.round((s % 3600) / 60); return h ? `${h}h ${m}m` : `${Math.max(1, m)} min`; };
const dayKey = (ts) => { const d = new Date(ts * 1000); return `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`; };
const trackOf = (id, m) => ({ videoId: id, title: m[0], artists: m[1] ? m[1].split(", ") : [], artistIds: m[3] ? [m[3]] : [], album: null, duration: null, thumbnail: m[2] || null });

/** Everything the page shows, for one time range. */
function compute(days) {
  const { log, meta } = store.getStats();
  const now = Date.now() / 1000, since = days ? now - days * DAY : 0;
  const ev = log.filter((e) => e[0] >= since);
  const tracks = new Map(), artists = new Map(), hours = new Array(24).fill(0);
  let secs = 0;
  for (const [ts, id, s] of ev) {
    secs += s;
    const t = tracks.get(id) || { id, plays: 0, secs: 0 }; t.plays++; t.secs += s; tracks.set(id, t);
    const m = meta[id]; const name = m?.[1]?.split(", ")[0];
    if (name) { const a = artists.get(name) || { name, plays: 0, secs: 0, id: m[3], thumb: m[2] }; a.plays++; a.secs += s; artists.set(name, a); }
    hours[new Date(ts * 1000).getHours()] += s;
  }
  // consecutive days with listening, counted back from today (or yesterday if nothing yet today)
  const dayset = new Set(log.map((e) => dayKey(e[0])));
  let streak = 0; const d = new Date();
  if (!dayset.has(dayKey(d.getTime() / 1000))) d.setDate(d.getDate() - 1);
  while (dayset.has(dayKey(d.getTime() / 1000))) { streak++; d.setDate(d.getDate() - 1); }
  return {
    ev, secs, meta, hours, streak,
    topTracks: [...tracks.values()].sort((a, b) => b.plays - a.plays || b.secs - a.secs).slice(0, 10),
    topArtists: [...artists.values()].sort((a, b) => b.secs - a.secs).slice(0, 8),
    bars: bars(ev, days),
  };
}

/** Minutes listened per day (week, month) or per month (year, all). */
function bars(ev, days) {
  const out = [], now = new Date();
  if (days && days <= 30) {
    const per = new Map(); ev.forEach((e) => per.set(dayKey(e[0]), (per.get(dayKey(e[0])) || 0) + e[2]));
    for (let i = days - 1; i >= 0; i--) {
      const d = new Date(now); d.setDate(d.getDate() - i);
      out.push({ v: per.get(dayKey(d.getTime() / 1000)) || 0, label: days === 7 ? "SMTWTFS"[d.getDay()] : (d.getDate() % 5 === 0 && i > 1) || i === 0 ? String(d.getDate()) : "" });
    }
    return out;
  }
  const per = new Map(); ev.forEach((e) => { const d = new Date(e[0] * 1000); const k = d.getFullYear() * 12 + d.getMonth(); per.set(k, (per.get(k) || 0) + e[2]); });
  const n = days ? 12 : Math.min(24, Math.max(6, per.size ? now.getFullYear() * 12 + now.getMonth() - Math.min(...per.keys()) + 1 : 6));
  for (let i = n - 1; i >= 0; i--) {
    const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
    out.push({ v: per.get(d.getFullYear() * 12 + d.getMonth()) || 0, label: "JFMAMJJASOND"[d.getMonth()] });
  }
  return out;
}

const barsHtml = (list, unit) => {
  const max = Math.max(1, ...list.map((b) => b.v));
  return `<div class="bars" role="img" aria-label="Listening ${unit}">${list.map((b) => `<div class="bar-col"><i style="height:${b.v ? Math.max(4, Math.round((b.v / max) * 100)) : 0}%" title="${fmtDur(b.v)}"></i><span>${b.label}</span></div>`).join("")}</div>`;
};

register("stats", () => {
  const header = `<header class="hdr"><h1 class="title">Analytics</h1><div class="right">${gear}</div></header>`;
  const all = store.getStats().log;
  if (!all.length) {
    page(header, empty("Nothing to show yet", "Play some music and your listening time, top songs and top artists show up here. It all stays on this device."));
    return;
  }
  const d = compute(RANGES[range][1]);
  const key = reg("topsongs", d.topTracks.map((t) => trackOf(t.id, d.meta[t.id] || ["", "", "", ""])));
  const topA = d.topArtists[0], topT = d.topTracks[0], topTrackMeta = topT && d.meta[topT.id];
  const peak = d.hours.indexOf(Math.max(...d.hours));
  const hour12 = (h) => `${h % 12 || 12} ${h < 12 ? "AM" : "PM"}`;
  const maxA = Math.max(1, ...d.topArtists.map((a) => a.secs));
  const maxH = Math.max(1, ...d.hours);
  page(header, `
    <div class="chips-row tight" role="group" aria-label="Time range">${RANGES.map(([l], i) => `<button class="chip${range === i ? " on" : ""}" data-act="stats-range" data-i="${i}">${l}</button>`).join("")}</div>
    ${d.ev.length >= 3 && topA && topT ? `
    <div class="wrapped">
      <div class="wr-k">${RANGES[range][0] === "All" ? "All time" : "This " + RANGES[range][0].toLowerCase()}</div>
      <div class="wr-big">${fmtDur(d.secs)}</div>
      <div class="wr-s">of music · mostly <b>${esc(topA.name)}</b></div>
      <div class="wr-row">
        <div><span>Top song</span><b>${esc(topTrackMeta?.[0] || "")}</b></div>
        <div><span>Peak hour</span><b>${d.secs ? hour12(peak) : "–"}</b></div>
      </div>
      <button class="btn" data-act="play" data-key="${key}" data-i="0">${ic("play", 18)}Play my top songs</button>
    </div>` : ""}
    <div class="stat-grid">
      <div class="stat"><b>${fmtDur(d.secs)}</b><span>Listening time</span></div>
      <div class="stat"><b>${d.ev.length}</b><span>Songs played</span></div>
      <div class="stat"><b>${new Set(d.ev.map((e) => d.meta[e[1]]?.[1]?.split(", ")[0]).filter(Boolean)).size}</b><span>Artists</span></div>
      <div class="stat"><b>${d.streak}</b><span>Day streak</span></div>
    </div>
    <div class="sec-head"><h2 class="h2" style="font-size:20px">${range <= 1 ? "Minutes per day" : "Minutes per month"}</h2></div>
    ${barsHtml(d.bars.map((b) => ({ ...b, v: b.v })), range <= 1 ? "per day" : "per month")}
    ${d.topArtists.length ? `<div class="sec-head"><h2 class="h2" style="font-size:20px">Top artists</h2></div>
    <div class="rank-list">${d.topArtists.map((a, i) => `
      <button class="rank-row" ${a.id ? `data-act="open" data-kind="artist" data-id="${esc(a.id)}"` : ""} aria-label="${esc(a.name)}">
        <i class="rk">${i + 1}</i>${a.thumb ? `<img class="cv round" loading="lazy" src="${art(a.thumb, 120)}" alt="">` : '<span class="cv round"></span>'}
        <span class="qmeta"><b>${esc(a.name)}</b><span>${a.plays} play${a.plays === 1 ? "" : "s"} · ${fmtDur(a.secs)}</span><em style="width:${Math.max(6, Math.round((a.secs / maxA) * 100))}%"></em></span>
      </button>`).join("")}</div>` : ""}
    ${d.topTracks.length ? `<div class="sec-head"><h2 class="h2" style="font-size:20px">Top songs</h2></div>
    <div class="qlist">${d.topTracks.map((t, i) => { const tr = trackOf(t.id, d.meta[t.id] || ["", "", "", ""]); return trackRow(tr, i, key, { sub: `${tr.artists[0] || ""} · ${t.plays} play${t.plays === 1 ? "" : "s"}` }); }).join("")}</div>` : ""}
    <div class="sec-head"><h2 class="h2" style="font-size:20px">When you listen</h2><span class="cap" style="margin:0">Around ${d.secs ? hour12(peak) : "–"}</span></div>
    <div class="bars hours" role="img" aria-label="Listening by hour of day">${d.hours.map((v, h) => `<div class="bar-col"><i style="height:${v ? Math.max(4, Math.round((v / maxH) * 100)) : 0}%"></i><span>${h % 6 === 0 ? hour12(h).replace(" ", "").toLowerCase() : ""}</span></div>`).join("")}</div>
    <p class="note" style="padding-top:20px">Worked out on this device from the songs you play. Nothing is uploaded. <button class="link-btn" data-act="stats-reset">Reset analytics</button></p>`);
});

actions["stats-range"] = (el) => { range = Number(el.dataset.i); rerender(); };
actions["stats-reset"] = () => {
  openSheet(`<div class="sheet-title">Reset analytics?</div><div class="sheet-pad"><p class="note" style="padding:0 0 12px">This clears your listening time, top songs and top artists. Likes, playlists and history stay.</p><button class="btn wide" style="background:#ff8a78;margin-bottom:10px" data-act="stats-reset-do">Reset</button><button class="btn wide ghost" data-act="sheet-close">Cancel</button></div>`);
};
actions["stats-reset-do"] = () => { store.clearStats(); closeSheet(); toast("Analytics reset"); rerender(); };
