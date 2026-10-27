// Mix tab: genres, moods and styles you add. Each one is searched for songs and playlists the moment it is added,
// and a blended "Play mix" queue is built from all of them.
import { api } from "./api.js";
import * as store from "./store.js";
import { ic } from "./icons.js";
import { $, $$, esc, toast, reg, trackShelf, collShelf, skShelf, fail } from "./ui.js";
import { register, page, setTab, rerender, getCur } from "./nav.js";
import { openSheet, closeSheet } from "./sheets.js";

export const actions = {};

const PRESETS = ["Lo-fi", "Tamil hip-hop", "90s Bollywood", "K-pop", "Indie", "Rock", "Jazz", "EDM", "Classical", "Devotional", "Punjabi", "Telugu hits", "Workout", "Acoustic"];
let sel = "all";                                  // "all" or a genre id
const loaded = new Map();                         // genre id → { songs, playlists }

const gear = `<button class="ib" data-act="open-settings" aria-label="Settings">${ic("gear", 22)}</button>`;
const addBtn = `<button class="ib" data-act="genre-add" aria-label="Add genre">${ic("plus", 24, { sw: 2 })}</button>`;
const suggChips = (names) => names.map((n) => `<button class="chip" data-act="genre-create" data-name="${esc(n)}">${esc(n)}</button>`).join("");
const header = `<header class="hdr"><h1 class="title">Mix</h1><div class="right">${addBtn}${gear}</div></header>`;

register("mix", () => {
  const genres = store.getGenres();
  if (!genres.length) {
    page(header, `
      <div class="empty"><b>Build your mixes</b><span>Add genres, moods or styles. Each one gets its own songs and playlists, found for you as soon as you add it.</span></div>
      <div class="chips-row wrap" style="justify-content:center">${suggChips(PRESETS)}</div>
      <div style="text-align:center;margin-top:18px"><button class="btn" data-act="genre-add">${ic("plus", 18, { sw: 2.2 })}Add your own</button></div>`);
    return;
  }
  if (sel !== "all" && !genres.some((g) => g.id === sel)) sel = "all";
  page(header, `
    <div class="chips-row hs" role="group" aria-label="Genres">
      <button class="chip${sel === "all" ? " on" : ""}" data-act="mix-pick" data-id="all">All</button>
      ${genres.map((g) => `<button class="chip${sel === g.id ? " on" : ""}" data-act="mix-pick" data-id="${esc(g.id)}">${esc(g.name)}</button>`).join("")}
      <button class="chip add" data-act="genre-add">${ic("plus", 16, { sw: 2.4 })}Add genre</button>
    </div>
    <div class="actions" id="mix-actions" hidden></div>
    ${genres.map((g) => `<section class="gblock" id="g-${esc(g.id)}"${sel !== "all" && sel !== g.id ? " hidden" : ""}>
      <div class="sec-head"><h2 class="h2">${esc(g.name)}</h2><button class="link-btn" data-act="genre-remove" data-id="${esc(g.id)}" aria-label="Remove ${esc(g.name)}">Remove</button></div>
      <div id="gb-${esc(g.id)}">${skShelf}</div></section>`).join("")}`);
  genres.forEach(loadGenre);
});

/** The searches happen here: songs and playlists for one genre, shown as soon as they arrive. */
async function loadGenre(g) {
  let d = loaded.get(g.id);
  if (!d) {
    try { d = await api(`/api/genre?q=${encodeURIComponent(g.name)}`); loaded.set(g.id, d); } catch { d = null; }
  }
  if (getCur() !== "mix") return;
  const box = document.getElementById("gb-" + g.id); if (!box) return;
  if (!d) { box.innerHTML = fail(esc(g.name), "reload-route"); return; }
  const songs = (d.songs || []).slice(0, 20), key = reg("g:" + g.id, songs);
  box.innerHTML = (songs.length
    ? `<div class="actions" style="margin-bottom:10px"><button class="btn" data-act="play" data-key="${key}" data-i="0">${ic("play", 18)}Play</button><button class="btn ghost" data-act="shuffle-list" data-key="${key}">${ic("shuffle", 18)}Shuffle</button></div>${trackShelf(songs, key)}`
    : '<p class="note">No songs found for this one. Try a more common name.</p>')
    + (d.playlists?.length ? `<div class="cap" style="margin:16px var(--gx) 8px">Playlists</div>${collShelf(d.playlists)}` : "");
  paintBlend();
}

/** One queue from every loaded genre, taking turns so no genre dominates. */
function paintBlend() {
  const box = $("#mix-actions"); if (!box) return;
  const ids = store.getGenres().map((g) => g.id).filter((id) => loaded.get(id)?.songs?.length);
  const cols = ids.map((id) => loaded.get(id).songs.slice(0, 12)), out = [], seen = new Set();
  for (let i = 0; i < 12; i++) for (const c of cols) { const t = c[i]; if (t && !seen.has(t.videoId)) { seen.add(t.videoId); out.push(t); } }
  if (!out.length) { box.hidden = true; return; }
  const key = reg("mixall", out);
  box.hidden = false;
  box.innerHTML = `<button class="btn" data-act="play" data-key="${key}" data-i="0">${ic("play", 18)}Play mix</button><button class="btn ghost" data-act="shuffle-list" data-key="${key}">${ic("shuffle", 18)}Shuffle</button><span class="cap" style="align-self:center;margin:0 0 0 4px">${out.length} songs from ${ids.length} genre${ids.length > 1 ? "s" : ""}</span>`;
}

actions["mix-pick"] = (el) => {
  sel = el.dataset.id;
  $$("[data-act=mix-pick]").forEach((c) => c.classList.toggle("on", c.dataset.id === sel));
  $$(".gblock").forEach((s) => { s.hidden = sel !== "all" && s.id !== "g-" + sel; });
};

/* ---------- add / remove ---------- */
actions["genre-add"] = () => {
  const have = new Set(store.getGenres().map((g) => g.id));
  const free = PRESETS.filter((n) => !have.has(n.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, "-").replace(/^-+|-+$/g, "")));
  openSheet(`<div class="sheet-title">Add a genre</div><div class="sheet-pad">
    <input class="field" id="genre-name" placeholder="Genre, mood or style (Lo-fi, Tamil hip-hop…)" maxlength="40" autocomplete="off" autocapitalize="off" aria-label="Genre name">
    <button class="btn wide" style="margin-top:12px" data-act="genre-create">Add and find songs</button>
    <div class="cap" style="margin:18px 0 10px">Suggestions</div>
    <div class="chips-row wrap" id="genre-sugg" style="padding:0">${suggChips(free)}</div></div>`);
  setTimeout(() => $("#genre-name")?.focus(), 80);
  // YouTube Music's own genre and mood names, when they load
  api("/api/explore").then((d) => {
    const box = $("#genre-sugg"); if (!box) return;
    const names = (d.moods || []).flatMap((s) => s.items.map((m) => m.title)).filter((n) => n && !PRESETS.includes(n) && !have.has(n.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, "-").replace(/^-+|-+$/g, "")));
    box.insertAdjacentHTML("beforeend", suggChips([...new Set(names)].slice(0, 30)));
  }).catch(() => {});
};
actions["genre-create"] = (el) => {
  const name = (el.dataset.name || $("#genre-name")?.value || "").trim().replace(/\s+/g, " ");
  if (!name) { toast("Type a genre first"); return; }
  const r = store.addGenre(name);
  closeSheet();
  sel = r.id;
  toast(r.added ? `Finding ${name} songs and playlists…` : `${name} is already in your mixes`);
  if (getCur() === "mix") rerender(); else setTab("mix");
};
actions["genre-remove"] = (el) => {
  const g = store.getGenres().find((x) => x.id === el.dataset.id); if (!g) return;
  openSheet(`<div class="sheet-title">Remove “${esc(g.name)}”?</div><div class="sheet-pad"><p class="note" style="padding:0 0 12px">It leaves your mixes. You can add it again any time.</p><button class="btn wide" style="background:#ff8a78;margin-bottom:10px" data-act="genre-remove-do" data-id="${esc(g.id)}">Remove</button><button class="btn wide ghost" data-act="sheet-close">Cancel</button></div>`);
};
actions["genre-remove-do"] = (el) => {
  store.removeGenre(el.dataset.id); loaded.delete(el.dataset.id);
  closeSheet(); toast("Removed");
  if (getCur() === "mix") rerender();
};

document.addEventListener("keydown", (e) => {
  if (e.key === "Enter" && e.target.id === "genre-name") { e.preventDefault(); document.querySelector('#sheet-body [data-act="genre-create"]')?.click(); }
});
