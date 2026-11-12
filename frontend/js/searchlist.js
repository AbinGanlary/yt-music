// Search a list: paste several songs, check the best match for each line, then play them, queue them or save them as a playlist.
import { art } from "./api.js";
import { active } from "./sources.js";
import * as P from "./player.js";
import * as store from "./store.js";
import { ic } from "./icons.js";
import { $, esc, toast, sub } from "./ui.js";
import { navigate } from "./nav.js";
import { openSheet, closeSheet } from "./sheets.js";
import { parseList } from "./backup.js";
import { refreshSide } from "./views.js";

export const actions = {};
const MAX = 60, PER = 4;
let rows = [];                               // { q, hits: [track], i: chosen hit, skip }

const chosen = () => rows.filter((r) => !r.skip && r.hits[r.i]).map((r) => r.hits[r.i]);

function open() {
  openSheet(`<div class="sheet-title">Search a list</div><div class="sheet-pad">
    <textarea class="field" id="sl-text" rows="7" style="resize:none" placeholder="One song per line:&#10;Excuses - AP Dhillon&#10;Blinding Lights - The Weeknd" aria-label="Songs to search for"></textarea>
    <button class="btn wide" style="margin-top:12px" data-act="sl-go">Find songs</button>
    <p class="fine" id="sl-msg">Each line is searched on YouTube Music. You check the best match before anything plays. Up to ${MAX} songs.</p></div>`);
}
actions["list-open"] = open;

actions["sl-go"] = async (el) => {
  const qs = [...new Set(parseList($("#sl-text")?.value || ""))].slice(0, MAX);
  const msg = $("#sl-msg");
  if (!qs.length) { toast("Type or paste some songs first"); return; }
  el.disabled = true;
  rows = qs.map((q) => ({ q, hits: [], i: 0, skip: false }));
  let next = 0, done = 0;
  const worker = async () => {
    while (next < rows.length) {
      const r = rows[next++];
      try { r.hits = (await active().search(r.q, { filter: "songs", limit: PER })).slice(0, PER); } catch { r.hits = []; }
      if (msg) msg.textContent = `Searching… ${++done} of ${rows.length}`;
    }
  };
  await Promise.all([worker(), worker(), worker()]);
  review();
};

function row(r, n) {
  const t = r.hits[r.i];
  if (!t) return `<div class="qrow md sl-miss"><span class="cv"></span><span class="qmeta"><b>${esc(r.q)}</b><span>No match found</span></span><span></span></div>`;
  const more = r.hits.length > 1 ? `<button class="chip sl-alt" data-act="sl-alt" data-n="${n}" aria-label="Try another match for ${esc(r.q)}">${r.i + 1}/${r.hits.length}</button>` : "";
  return `<div class="qrow md${r.skip ? " sl-off" : ""}">
    <img class="cv" loading="lazy" decoding="async" src="${art(t.thumbnail, 120)}" alt="">
    <span class="qmeta"><b>${esc(t.title)}</b><span>${esc(sub(t))} · for “${esc(r.q)}”</span></span>
    <span style="display:flex;align-items:center;gap:2px">${more}<button class="ib" data-act="sl-skip" data-n="${n}" aria-label="${r.skip ? "Include" : "Leave out"} ${esc(t.title)}">${ic(r.skip ? "plus" : "close", 18)}</button></span></div>`;
}

function review() {
  const list = chosen(), miss = rows.filter((r) => !r.hits.length).length;
  openSheet(`<div class="sheet-title">${list.length} song${list.length === 1 ? "" : "s"} found</div><div class="sheet-pad">
    <p class="fine" style="margin:0 0 8px">Tap <b>1/4</b> to see the next match for a line, or ✕ to leave a song out.${miss ? ` ${miss} line${miss > 1 ? "s" : ""} had no match.` : ""}</p>
    <div class="sl-list">${rows.map(row).join("")}</div>
    <div class="rt-actions" style="margin-top:12px"><button class="btn" data-act="sl-play"${list.length ? "" : " disabled"}>Play all</button><button class="btn ghost" data-act="sl-queue"${list.length ? "" : " disabled"}>Add to queue</button></div>
    <input class="field" id="sl-name" placeholder="Playlist name" maxlength="60" autocomplete="off" aria-label="Playlist name" style="margin-top:10px">
    <button class="btn ghost wide" style="margin-top:8px" data-act="sl-save"${list.length ? "" : " disabled"}>Save as playlist</button></div>`);
}
const keepName = () => $("#sl-name")?.value || "";
function redraw() { const name = keepName(); review(); if (name && $("#sl-name")) $("#sl-name").value = name; }

actions["sl-alt"] = (el) => { const r = rows[Number(el.dataset.n)]; if (r) { r.i = (r.i + 1) % r.hits.length; redraw(); } };
actions["sl-skip"] = (el) => { const r = rows[Number(el.dataset.n)]; if (r) { r.skip = !r.skip; redraw(); } };
actions["sl-play"] = () => { const l = chosen(); if (!l.length) return; closeSheet(); P.playList(l, 0); toast(`Playing ${l.length} song${l.length === 1 ? "" : "s"}`); };
actions["sl-queue"] = () => { const l = chosen(); if (!l.length) return; l.forEach((t) => P.addToQueue(t)); closeSheet(); toast(`Added ${l.length} to the queue`); };
actions["sl-save"] = () => {
  const l = chosen(); if (!l.length) return;
  const id = store.createPlaylist(keepName().trim() || "Song list", l);
  closeSheet(); refreshSide(); toast(`Saved ${l.length} song${l.length === 1 ? "" : "s"}`);
  navigate({ name: "local", id });
};
