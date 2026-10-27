// Page views. Each registers a renderer with nav.js; click handlers for view-specific data-act names live in `actions`.
import { api, art, isNative, isDevice, getBase, getSource, checkConnection, resetConnection, signedIn, accountName } from "./api.js";
import * as store from "./store.js";
import * as P from "./player.js";
import * as S from "./settings.js";
import { ic, logo } from "./icons.js";
import {
  $, $$, esc, APP_NAME, APP_VERSION, toast, lists, reg, artistReg, sub, gradient, cover, trackRows, trackShelf, collShelf, shelf,
  collCard, skShelf, skRows, fail, empty, hue, applyAccent,
} from "./ui.js";
import { register, page, navigate, setTab, rerender, getCur, getRoute, view, scroller, canGoBack } from "./nav.js";

export const actions = {};

/* ---------- header helpers ---------- */
const hdrMain = (title, right = "", cls = "") => `<header class="hdr ${cls}"><h1 class="title">${title}</h1><div class="right">${right}</div></header>`;
const hdrBack = (title, right = "") => `<header class="hdr back"><button class="ib" data-act="back" aria-label="Back">${ic("back", 24, { sw: 2 })}</button><h1 class="title sm">${esc(title)}</h1><span class="grow"></span>${right}</header>`;
const gearBtn = `<button class="ib" data-act="open-settings" aria-label="Settings">${ic("gear", 22)}</button>`;
const searchBtn = `<button class="ib" data-act="go-search" aria-label="Search">${ic("search", 22)}</button>`;
const isIOS = /iphone|ipad|ipod/i.test(navigator.userAgent);
const standalone = isNative() || window.navigator.standalone || matchMedia("(display-mode: standalone)").matches;
const greetingName = () => { const h = new Date().getHours(); return h < 5 ? "Still up" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"; };

/* explore data is shared by Home chips and the Explore page */
let exploreP = null;
const exploreData = () => (exploreP ??= api("/api/explore").catch((e) => { exploreP = null; throw e; }));
S.bus.addEventListener("change", (e) => { if ("location" in e.detail || "country" in e.detail || "global" in e.detail) { exploreP = null; chartScope = null; } });

/* =============================== HOME =============================== */
// [label, YouTube Music mood name]. "All" (homeMood = -1) is the normal Home feed; a mood replaces it with that mood's playlists and songs.
const HOME_MOODS = [["Relax", "Chill"], ["Sleep", "Sleep"], ["Energize", "Energize"], ["Sad", "Sad"], ["Romance", "Romance"], ["Feel good", "Feel good"], ["Workout", "Workout"], ["Focus", "Focus"], ["Commute", "Commute"], ["Party", "Party"]];
let homeMood = -1;

register("home", () => {
  const hist = store.getHistory(), tt = S.getTaste();
  const header = `<header class="hdr home-hdr"><div class="brand">${logo(28)}<span class="brand-name">${APP_NAME}</span></div><div class="right">${searchBtn}${gearBtn}</div></header>`;
  const installBanner = isIOS && !standalone && !store.kv.get("hideInstall", false)
    ? `<div class="banner"><button class="ib x" data-act="hide-install" aria-label="Dismiss">${ic("close", 18)}</button><b>Install ${APP_NAME}.</b> Tap <b>Share</b>, then <b>Add to Home Screen</b> for lock-screen controls and background play.</div>` : "";
  const tasteBanner = !S.hasTaste() && !store.kv.get("hideTaste", false)
    ? `<div class="banner"><button class="ib x" data-act="hide-taste" aria-label="Dismiss">${ic("close", 18)}</button><b>Make it yours.</b> Pick your music languages and a few artists you like, and Home and your queue will follow.<br><button class="btn sm" data-act="open-taste">Pick now</button></div>` : "";
  page(header, `
    <div class="chips-row hs" role="group" aria-label="Moods"><button class="chip${homeMood < 0 ? " on" : ""}" data-act="home-mood" data-i="-1" aria-pressed="${homeMood < 0}">All</button>${HOME_MOODS.map(([label], i) => `<button class="chip${homeMood === i ? " on" : ""}" data-act="home-mood" data-i="${i}" aria-pressed="${homeMood === i}">${label}</button>`).join("")}</div>
    <div id="moodbox"></div>
    <div id="home-rest"${homeMood >= 0 ? " hidden" : ""}>
    ${installBanner}${tasteBanner}
    <div id="ytsec"></div>
    ${hist.length ? `<h2 class="h2">Listen again</h2>${trackShelf(hist.slice(0, 12), reg("hist", hist.slice(0, 12)), false, "grid-d")}` : ""}
    <div id="mix"></div>
    <div id="because"></div>
    <div class="sec-head"><div><div class="cap" style="margin:0">Start radio from a song</div><h2 class="h2">Quick picks</h2></div><button class="btn ghost sm d-only" data-act="play" data-key="quick" data-i="0">Play all</button></div>
    <div id="quick" class="qlist cols">${skRows}</div>
    <div style="height:28px"></div>
    <h2 class="h2">Trending</h2>
    <div id="trend">${skShelf}</div>
    </div>`);
  if (homeMood >= 0) loadHomeMood();
  if (signedIn()) loadYtHome();

  if (S.hasTaste()) {
    const label = [...tt.artists.slice(0, 2).map((a) => a.name), ...tt.languages.slice(0, 1)].join(", ");
    $("#mix").innerHTML = `<div class="sec-head"><h2 class="h2">Picked for you</h2><span class="cap" style="margin:0">${esc(label)}</span></div>${skShelf}`;
    const ids = tt.artists.slice(0, 6).map((a) => a.browseId).join(",");
    api(`/api/mix?artists=${encodeURIComponent(ids)}&langs=${encodeURIComponent(tt.languages.slice(0, 3).join(","))}`).then((list) => {
      if (getCur() !== "home") return;
      $("#mix").innerHTML = list.length ? `<div class="sec-head"><h2 class="h2">Picked for you</h2><span class="cap" style="margin:0">${esc(label)}</span></div>${trackShelf(list.slice(0, 16), reg("mix", list))}` : "";
    }).catch(() => { $("#mix") && ($("#mix").innerHTML = ""); });
  }
  if (hist[0]) {
    const h = `<div class="sec-head"><h2 class="h2">Because you played <i>${esc(hist[0].title)}</i></h2></div>`;
    $("#because").innerHTML = h + skShelf;
    api(`/api/radio/${hist[0].videoId}`).then((r) => {
      const list = r.filter((t) => t.videoId !== hist[0].videoId).slice(0, 14);
      if (getCur() !== "home") return;
      $("#because").innerHTML = list.length ? h + trackShelf(list, reg("because", list)) : "";
    }).catch(() => { $("#because") && ($("#because").innerHTML = ""); });
  }
  api("/api/home").then((secs) => {
    const items = [], seen = new Set();
    secs.flatMap((s) => s.items).forEach((t) => { if (!seen.has(t.videoId)) { seen.add(t.videoId); items.push(t); } });
    if (getCur() === "home") $("#quick").innerHTML = items.length ? trackRows(items.slice(0, 12), reg("quick", items.slice(0, 12))) : '<p class="note">Nothing here yet. Try searching.</p>';
  }).catch(() => getCur() === "home" && ($("#quick").innerHTML = fail("your picks", "reload-home")));
  api(`/api/trending?country=${S.loc() || "ZZ"}`).then((t) => {
    if (getCur() === "home") $("#trend").innerHTML = t.length ? trackShelf(t.slice(0, 20), reg("trend", t.slice(0, 20)), true) : '<p class="note">No chart right now.</p>';
  }).catch(() => getCur() === "home" && ($("#trend").innerHTML = ""));
});

/** The signed-in account's own YouTube Music home (Settings → Account), above the app's own sections. */
function loadYtHome() {
  api("/api/ythome").then((shelves) => {
    const box = $("#ytsec"); if (getCur() !== "home" || !box) return;
    const liked = `<div class="chips-row tight"><button class="chip" data-act="open" data-kind="liked" data-id="LM">${ic("thumb", 15)} Your liked songs</button></div>`;
    box.innerHTML = liked + shelves.slice(0, 4).map((s, i) =>
      `<div class="sec-head"><h2 class="h2">${esc(s.title)}</h2></div>${s.kind === "tracks" ? trackShelf(s.items.slice(0, 16), reg("yth" + i, s.items)) : collShelf(s.items.slice(0, 16))}`).join("");
  }).catch(() => { const box = $("#ytsec"); if (box) box.innerHTML = ""; });
}

async function loadHomeMood() {
  const box = $("#moodbox"); if (!box || homeMood < 0) return;
  const [label, apiName] = HOME_MOODS[homeMood];
  box.innerHTML = `<h2 class="h2">${label}</h2>${skShelf}`;
  try {
    const d = await exploreData();
    const m = d.moods.flatMap((s) => s.items).find((x) => x.title.toLowerCase() === apiName.toLowerCase());
    if (!m) { box.innerHTML = ""; return; }
    const pls = await api(`/api/mood?params=${encodeURIComponent(m.params)}`);
    if (getCur() !== "home" || homeMood < 0 || HOME_MOODS[homeMood][0] !== label) return;
    if (!pls.length) { box.innerHTML = `<p class="note">Nothing found for ${esc(label)} right now.</p>`; return; }
    const head = `<h2 class="h2">${label}</h2>${collShelf(pls.slice(0, 14))}`;
    box.innerHTML = head + `<div style="height:20px"></div><h2 class="h2">Songs for ${esc(label.toLowerCase())}</h2><div id="mood-songs">${skRows}</div>`;
    const first = pls.find((p) => p.kind === "playlist") || pls[0];            // the songs come from the first playlist
    const pd = await api(`/api/${first.kind}/${encodeURIComponent(first.id)}`);
    if (getCur() !== "home" || homeMood < 0 || HOME_MOODS[homeMood][0] !== label || !$("#mood-songs")) return;
    const list = (pd.tracks || []).slice(0, 15);
    $("#mood-songs").innerHTML = list.length ? `<div class="qlist cols">${trackRows(list, reg("moodsongs", list))}</div>` : '<p class="note">No songs to show.</p>';
  } catch { if ($("#mood-songs")) $("#mood-songs").innerHTML = ""; else if ($("#moodbox") && !$("#moodbox").innerHTML.includes("shelf")) $("#moodbox").innerHTML = ""; }
}
actions["home-mood"] = (el) => {
  const i = Number(el.dataset.i);
  homeMood = homeMood === i ? -1 : i;
  $$(".chips-row .chip[data-act=home-mood]").forEach((c) => { const on = Number(c.dataset.i) === homeMood; c.classList.toggle("on", on); c.setAttribute("aria-pressed", on); });
  $("#home-rest").hidden = homeMood >= 0;
  if (homeMood < 0) $("#moodbox").innerHTML = ""; else loadHomeMood();
};
actions["reload-home"] = () => rerender();
actions["hide-install"] = () => { store.kv.set("hideInstall", true); rerender(); };
actions["hide-taste"] = () => { store.kv.set("hideTaste", true); rerender(); };

/* =============================== EXPLORE =============================== */
let chartScope = null;                                   // null = follow the Global content setting
const moodReg = [];
/** Which chart the Explore page shows: worldwide while Global content is on (or there is no known country). */
const curScope = () => chartScope ?? (S.get().global || !S.localLoc() ? "global" : "local");

/** The Moods & genres tiles: bold gradients, one colour pair per mood. */
function moodTiles(d) {
  moodReg.length = 0;
  return d.moods.map((sec) => `
      <div class="tiles-h">${esc(sec.section)}</div>
      <div class="tiles">${sec.items.map((m) => { const i = moodReg.push(m) - 1; return `<button class="tile" style="--h:${hue(m.title)}" data-act="open-mood" data-i="${i}"><span>${esc(m.title)}</span><i aria-hidden="true"></i></button>`; }).join("")}</div>`).join("");
}

register("explore", () => {
  const here = S.localLoc() ? S.regionName(S.localLoc()) : "";
  page(hdrMain("Explore", searchBtn + gearBtn), `
    <div class="sec-head"><h2 class="h2">New releases</h2><span class="cap" style="margin:0">Albums &amp; singles</span></div>
    <div id="x-new">${skShelf}</div>
    <div class="sec-head"><h2 class="h2">Charts</h2></div>
    <div class="chips-row tight" role="group" aria-label="Chart region">
      ${here ? `<button class="chip${curScope() === "local" ? " on" : ""}" data-act="chart-scope" data-v="local">${esc(here)}</button>` : ""}
      <button class="chip${curScope() === "global" ? " on" : ""}" data-act="chart-scope" data-v="global">Global</button>
    </div>
    <div id="x-charts">${skShelf}</div>
    <div class="sec-head"><h2 class="h2" style="font-size:20px">Top artists</h2></div>
    <div id="x-artists">${skShelf}</div>
    <div class="sec-head"><h2 class="h2">Moods &amp; genres</h2></div>
    <div id="x-moods"><div class="tiles">${'<div class="sk tile"></div>'.repeat(8)}</div></div>`);
  exploreData().then((d) => {
    if (getCur() !== "explore") return;
    $("#x-new").innerHTML = d.newReleases.length ? collShelf(d.newReleases) : '<p class="note">Nothing new right now.</p>';
    $("#x-moods").innerHTML = moodTiles(d);
  }).catch(() => { if (getCur() === "explore") { $("#x-new").innerHTML = fail("new releases", "reload-explore"); $("#x-moods").innerHTML = ""; } });
  loadCharts();
});
function loadCharts() {
  const country = curScope() === "global" || !S.localLoc() ? "ZZ" : S.localLoc();
  api(`/api/charts?country=${country}`).then((d) => {
    if (getCur() !== "explore") return;
    $("#x-charts").innerHTML = d.playlists.length ? collShelf(d.playlists) : '<p class="note">No charts for this country.</p>';
    d.artists.forEach((a) => artistReg.set(a.id, a));
    $("#x-artists").innerHTML = d.artists.length ? collShelf(d.artists.slice(0, 20)) : "";
  }).catch(() => { if (getCur() === "explore") { $("#x-charts").innerHTML = fail("charts", "reload-explore"); $("#x-artists").innerHTML = ""; } });
}
actions["reload-explore"] = () => rerender();
actions["chart-scope"] = (el) => {
  chartScope = el.dataset.v;
  $$("[data-act=chart-scope]").forEach((c) => c.classList.toggle("on", c.dataset.v === curScope()));
  $("#x-charts").innerHTML = skShelf; $("#x-artists").innerHTML = skShelf; loadCharts();
};
actions["open-mood"] = (el) => { const m = moodReg[Number(el.dataset.i)]; if (m) navigate({ name: "mood", params: m.params, title: m.title }); };

register("mood", ({ params, title }) => {
  page(hdrBack(title), `<div id="m-body" class="grid2">${'<div class="sk card" style="width:100%;flex:none;aspect-ratio:1;height:auto"></div>'.repeat(6)}</div>`);
  api(`/api/mood?params=${encodeURIComponent(params)}`).then((pls) => {
    if (getCur() !== "mood") return;
    $("#m-body").innerHTML = pls.length ? pls.map((c) => collCard(c, true)).join("") : '<p class="note">Nothing here.</p>';
  }).catch(() => { getCur() === "mood" && ($("#m-body").innerHTML = fail("playlists", "reload-route")); });
});
actions["reload-route"] = () => rerender();

/* =============================== SEARCH =============================== */
let searchState = { q: "", filter: "songs", results: null };
let suggT;
export const getSearchQuery = () => searchState.q;

register("search", () => {
  view.innerHTML = `
    <div class="searchbar" style="display:flex;align-items:center;gap:4px;padding-left:${canGoBack() ? 8 : 20}px">
      ${canGoBack() ? `<button class="ib" data-act="back" aria-label="Back">${ic("back", 24, { sw: 2 })}</button>` : ""}
      <div class="sbox grow">${ic("search", 20)}<input id="q" type="search" inputmode="search" enterkeyhint="search" autocomplete="off" autocapitalize="off" spellcheck="false" placeholder="Search songs, albums, artists" aria-label="Search" value="${esc(searchState.q)}"><button class="ib dim" data-act="q-clear" aria-label="Clear" style="width:32px;height:32px;${searchState.q ? "" : "display:none"}">${ic("close", 18)}</button></div>
    </div>
    <div class="chips-row tight" style="padding-top:12px" role="group" aria-label="Result type">
      <button class="chip${searchState.filter === "songs" ? " on" : ""}" data-act="filter" data-f="songs">Songs</button>
      <button class="chip${searchState.filter === "videos" ? " on" : ""}" data-act="filter" data-f="videos">Videos</button>
    </div>
    <main class="scroll"><div id="s-body"></div></main>`;
  const q = $("#q");
  q.addEventListener("input", () => {
    searchState.q = q.value;
    $("[data-act=q-clear]").style.display = q.value ? "" : "none";
    clearTimeout(suggT); suggT = setTimeout(showSuggest, 200);
  });
  q.addEventListener("keydown", (e) => { if (e.key === "Enter") { q.blur(); doSearch(q.value); } });
  if (searchState.results && searchState.q) drawResults(); else { showSuggest(); if (!searchState.q) q.focus(); }
});
async function showSuggest() {
  const body = $("#s-body"); if (!body) return;
  const q = searchState.q.trim();
  const li = (s) => `<li data-act="suggest" data-q="${esc(s)}">${ic("search", 18)}${esc(s)}</li>`;
  if (!q) {
    const r = store.getRecentSearches();
    body.innerHTML = (r.length ? `<div class="sec-head" style="margin-top:8px"><h2 class="h2" style="font-size:20px">Recent</h2><button class="link-btn" data-act="recent-clear">Clear</button></div><ul class="sugg">${r.map(li).join("")}</ul>` : '<p class="note">Search for a song, artist or album. Play one and the queue keeps going on its own.</p>') + '<div id="s-moods"></div>';
    exploreData().then((d) => {                                   // browse tiles under the recent searches
      if (getCur() !== "search" || searchState.q.trim() || !$("#s-moods")) return;
      $("#s-moods").innerHTML = `<div class="sec-head" style="margin-top:12px"><h2 class="h2" style="font-size:20px">Browse all</h2></div>` + moodTiles(d);
    }).catch(() => {});
    return;
  }
  try {
    const s = await api(`/api/suggest?q=${encodeURIComponent(q)}`);
    if ($("#q")?.value.trim() !== q) return;
    body.innerHTML = `<ul class="sugg">${s.map(li).join("")}</ul>`;
  } catch {}
}
export async function doSearch(q) {
  q = q.trim(); if (!q) return;
  searchState.q = q; searchState.results = null;
  store.addRecentSearch(q);
  if (getCur() !== "search") { navigate({ name: "search" }); }
  const inp = $("#q"); if (inp) inp.value = q;
  const dq = $("#dq"); if (dq) dq.value = q;
  $("#s-body").innerHTML = skRows;
  try {
    searchState.results = await api(`/api/search?q=${encodeURIComponent(q)}&filter=${searchState.filter}`);
    if (getCur() === "search") drawResults();
  } catch { if (getCur() === "search") $("#s-body").innerHTML = fail("results", "retry-search"); }
}
function drawResults() {
  const r = searchState.results || [];
  $("#s-body").innerHTML = r.length
    ? `<div class="actions"><button class="btn" data-act="play" data-key="${reg("search", r)}" data-i="0">${ic("play", 18)}Play all</button><button class="btn ghost" data-act="shuffle-list" data-key="search">${ic("shuffle", 18)}Shuffle</button></div><div class="qlist">${trackRows(r, "search")}</div>`
    : '<p class="note">No results. Try different words.</p>';
}
actions["go-search"] = () => navigate({ name: "search" });
actions["filter"] = (el) => {
  searchState.filter = el.dataset.f; searchState.results = null;
  $$(".chip[data-act=filter]").forEach((c) => c.classList.toggle("on", c.dataset.f === searchState.filter));
  if (searchState.q.trim()) doSearch(searchState.q);
};
actions["q-clear"] = () => { searchState.q = ""; searchState.results = null; const dq = $("#dq"); if (dq) dq.value = ""; rerender(); $("#q")?.focus(); };
actions["suggest"] = (el) => doSearch(el.dataset.q);
actions["retry-search"] = () => doSearch(searchState.q);
actions["recent-clear"] = () => { store.clearRecentSearches(); showSuggest(); };

/* =============================== LIBRARY =============================== */
const LIB_TABS = ["All", "Playlists", "Albums", "Artists"];
const LIB_KINDS = [null, "Playlist", "Album", "Artist"];
let libTab = 0, libSort = 0, libDlOnly = false, libSearch = false, libQ = "";
let libItems = [];

const allSaved = (tracks) => tracks.length > 0 && tracks.every((t) => store.downloadedIds.has(t.videoId));
function buildLibrary() {
  const likes = store.getLikes(), hist = store.getHistory();
  const items = [
    { kind: "Playlist", title: "Liked music", sub: `Auto playlist · ${likes.length} songs`, grad: "linear-gradient(135deg,#6d5bd0,#d6c8ff)", icon: "thumb", dl: allSaved(likes), open: { name: "local", id: "liked" } },
    { kind: "Playlist", title: "Listening history", sub: `Auto playlist · ${hist.length} songs`, grad: "linear-gradient(145deg,#0e1b3d,#2a3f8f 50%,#5ad1e6)", icon: "clock", dl: false, open: { name: "local", id: "history" } },
  ];
  store.getPlaylists().forEach((p) => items.push({ kind: "Playlist", title: p.name, sub: `Playlist · You · ${p.tracks.length} songs`, thumb: p.tracks[0]?.thumbnail, dl: allSaved(p.tracks), open: { name: "local", id: p.id }, at: p.at }));
  store.getSaved().forEach((s) => items.push({
    kind: s.kind === "artist" ? "Artist" : s.kind === "album" ? "Album" : "Playlist", title: s.title,
    sub: s.kind === "artist" ? "Artist · Following" : `${s.kind === "album" ? "Album" : "Playlist"} · ${s.subtitle || "YouTube Music"}`,
    thumb: s.thumbnail, round: s.kind === "artist", dl: false, open: { name: "collection", kind: s.kind, id: s.id }, at: s.at,
  }));
  return items;
}
register("library", () => {
  const all = buildLibrary();
  let list = all.filter((x) => (!LIB_KINDS[libTab] || x.kind === LIB_KINDS[libTab]) && (!libDlOnly || x.dl) && (!libQ || x.title.toLowerCase().includes(libQ.toLowerCase())));
  if (libSort === 1) list = list.slice().sort((a, b) => a.title.localeCompare(b.title));
  libItems = list;
  const header = hdrMain("Library",
    `<button class="ib" data-act="lib-search" aria-label="Search library">${ic("search", 22)}</button><button class="ib" data-act="new-playlist" aria-label="New playlist">${ic("plus", 22, { sw: 2 })}</button>`);
  const cv = (x) => x.thumb ? cover(x.thumb, `xl${x.round ? " round" : ""}`, x.title)
    : x.grad ? `<span class="cv xl" style="background:${x.grad};display:grid;place-items:center;color:#fff">${x.icon ? ic(x.icon, 26, { fill: x.icon === "thumb" }) : ""}</span>`
    : cover(null, `xl${x.round ? " round" : ""}`, x.title);
  const rows = list.map((x, i) => `
    <div class="qrow xl" role="button" tabindex="0" data-act="lib-open" data-i="${i}" aria-label="Open ${esc(x.title)}">
      ${cv(x)}<span class="qmeta"><b>${esc(x.title)}</b><span>${esc(x.sub)}</span></span>
      ${x.dl ? `<span class="badge-dl" role="img" aria-label="Downloaded">${ic("check", 14, { sw: 3 })}</span>` : "<span></span>"}
    </div>`).join("");
  const body = `
    ${libSearch ? `<div style="padding:4px var(--gx) 12px"><div class="sbox">${ic("search", 20)}<input id="lib-q" type="search" placeholder="Search your library" autocomplete="off" aria-label="Search your library" value="${esc(libQ)}"></div></div>` : ""}
    <div class="chips-row tight hs" role="tablist" aria-label="Library filter">${LIB_TABS.map((l, i) => `<button class="chip${libTab === i ? " on" : ""}" role="tab" aria-selected="${libTab === i}" data-act="lib-chip" data-i="${i}">${l}</button>`).join("")}<button class="chip" data-act="go-downloads">${ic("download", 15)} Downloads</button></div>
    <div class="sortbar">
      <button class="sortbtn" data-act="lib-sort" aria-label="Sort by ${libSort ? "A to Z" : "Recently added"}">${ic("sort", 18, { sw: 2 })}${libSort ? "A to Z" : "Recently added"}</button>
      <button class="dlonly" data-act="lib-dlonly" role="switch" aria-checked="${libDlOnly}">Downloaded only<span class="switch s${libDlOnly ? " on" : ""}"><i></i></span></button>
    </div>
    <div class="qlist" style="padding-top:4px">${rows}</div>
    ${list.length ? "" : libDlOnly ? empty("Nothing downloaded here yet", "Download a playlist to listen without a connection.") : empty("Nothing here yet", libTab === 3 ? "Follow artists from their page." : libTab === 2 ? "Save albums from their page." : "Create a playlist with + or save songs from the ⋯ menu.")}`;
  page(header, body);
  const lq = $("#lib-q");
  if (lq) { lq.addEventListener("input", () => { libQ = lq.value; const pos = lq.selectionStart; rerender(); const n = $("#lib-q"); n?.focus(); n?.setSelectionRange(pos, pos); }); if (!libQ) lq.focus(); }
});
actions["lib-chip"] = (el) => { libTab = Number(el.dataset.i); rerender(); };
actions["lib-sort"] = () => { libSort = (libSort + 1) % 2; rerender(); };
actions["lib-dlonly"] = () => { libDlOnly = !libDlOnly; rerender(); };
actions["lib-search"] = () => { libSearch = !libSearch; if (!libSearch) libQ = ""; rerender(); };
actions["lib-open"] = (el) => { const it = libItems[Number(el.dataset.i)]; if (it) navigate(it.open); };
actions["open-local"] = (el) => navigate({ name: "local", id: el.dataset.id });

/* =============================== DOWNLOADS =============================== */
register("downloads", async () => {
  const dls = await store.listDownloads().catch(() => []);
  if (getCur() !== "downloads") return;
  const tracks = dls.map((d) => d.track), size = dls.reduce((n, d) => n + (d.size || 0), 0);
  const key = reg("dls", tracks);
  page(hdrMain("Downloads", gearBtn), `
    <p class="note" style="padding-top:4px">${dls.length ? `${dls.length} song${dls.length === 1 ? "" : "s"} · ${(size / 1048576).toFixed(0)} MB on this device. They play without internet.` : ""}</p>
    ${tracks.length ? `<div class="actions" style="padding-top:0"><button class="btn" data-act="play" data-key="${key}" data-i="0">${ic("play", 18)}Play all</button><button class="btn ghost" data-act="shuffle-list" data-key="${key}">${ic("shuffle", 18)}Shuffle</button></div><div class="qlist">${trackRows(tracks, key)}</div>`
      : empty("Nothing downloaded yet", "Open a song's ⋯ menu and choose Download to listen without a connection.")}`);
});

/* =============================== LOCAL LISTS (liked, history, your playlists) =============================== */
register("local", ({ id }) => {
  let title, tracks, kicker = "Playlist", cov, isPl = false;
  if (id === "liked") { title = "Liked music"; tracks = store.getLikes(); kicker = "Auto playlist"; cov = `<span class="cover" style="background:linear-gradient(135deg,#6d5bd0,#d6c8ff);display:grid;place-items:center;color:#fff">${ic("thumb", 56, { fill: true })}</span>`; }
  else if (id === "history") { title = "Listening history"; tracks = store.getHistory(); kicker = "Auto playlist"; cov = `<span class="cover" style="background:linear-gradient(145deg,#0e1b3d,#2a3f8f 50%,#5ad1e6);display:grid;place-items:center;color:#fff">${ic("clock", 56)}</span>`; }
  else {
    const p = store.getPlaylist(id);
    if (!p) { rerenderTo(); return; }
    title = p.name; tracks = p.tracks; isPl = true;
    cov = p.tracks[0]?.thumbnail ? `<img class="cover" src="${art(p.tracks[0].thumbnail, 400)}" alt="">` : `<span class="cover" style="background:${gradient(p.name)};display:grid;place-items:center;font-family:var(--display);font-weight:700;font-size:52px">${esc(p.name.charAt(0).toUpperCase())}</span>`;
  }
  const key = reg("local", tracks);
  page(hdrBack(""), `
    <div class="hero">${cov}<div class="hero-t"><div class="cap">${kicker}</div><h1>${esc(title)}</h1><p>${tracks.length} song${tracks.length === 1 ? "" : "s"}</p></div></div>
    ${tracks.length ? `<div class="actions"><button class="btn" data-act="play" data-key="${key}" data-i="0">${ic("play", 18)}Play</button><button class="btn ghost" data-act="shuffle-list" data-key="${key}">${ic("shuffle", 18)}Shuffle</button>${isPl ? `<button class="btn ghost" data-act="pl-rename" data-id="${esc(id)}">Rename</button><button class="btn ghost" data-act="pl-delete" data-id="${esc(id)}">Delete</button>` : ""}</div>`
      : isPl ? `<div class="actions"><button class="btn ghost" data-act="pl-rename" data-id="${esc(id)}">Rename</button><button class="btn ghost" data-act="pl-delete" data-id="${esc(id)}">Delete</button></div>` : ""}
    ${tracks.length ? `<div class="qlist">${trackRows(tracks, key, { ctx: isPl ? "pl:" + id : "" })}</div>` : empty("No songs yet", id === "liked" ? "Songs you like show up here." : id === "history" ? "Nothing played yet." : "Add songs from any song's ⋯ menu → Save to playlist.")}`);
});
function rerenderTo() { setTab("library"); }

/* =============================== ALBUM / PLAYLIST / ARTIST PAGES =============================== */
let lastColl = null;
register("collection", ({ kind, id }) => {
  page(hdrBack(""), `<div id="c-body"><div class="hero"><div class="sk cover"></div><div class="hero-t"><div class="sk" style="height:34px;width:70%"></div></div></div>${skRows}</div>`);
  api(`/api/${kind}/${encodeURIComponent(id)}`).then((d) => {
    if (getCur() !== "collection") return;
    lastColl = { kind, id, title: d.title, subtitle: d.subtitle, thumbnail: d.thumbnail };
    const key = reg("coll", d.tracks), round = kind === "artist";
    const saved = store.isSaved(kind, id);
    $("#c-body").innerHTML = `
      <div class="hero"><img class="cover${round ? " round" : ""}" src="${art(d.thumbnail, 600)}" alt=""><div class="hero-t"><div class="cap">${kind === "artist" ? "Artist" : kind === "album" ? "Album" : "Playlist"}</div><h1>${esc(d.title)}</h1><p>${esc([d.subtitle, d.meta].filter(Boolean).join(" · "))}</p></div></div>
      <div class="actions">
        ${d.tracks.length ? `<button class="btn" data-act="play" data-key="${key}" data-i="0">${ic("play", 18)}Play</button><button class="btn ghost" data-act="shuffle-list" data-key="${key}">${ic("shuffle", 18)}Shuffle</button>` : ""}
        ${kind === "artist" && d.radioVideoId ? `<button class="btn ghost" data-act="artist-radio" data-id="${d.radioVideoId}">${ic("radio", 18)}Radio</button>` : ""}
        <button class="btn ghost" data-act="save-coll" id="save-coll">${saved ? (kind === "artist" ? "Following" : "In library") : (kind === "artist" ? "Follow" : "Save to library")}</button>
      </div>
      ${d.tracks.length ? `<div class="qlist">${trackRows(d.tracks, key)}</div>` : '<p class="note">No songs to show.</p>'}
      ${d.albums?.length ? `<div style="height:20px"></div><h2 class="h2">Albums</h2>${collShelf(d.albums)}` : ""}`;
  }).catch(() => { getCur() === "collection" && ($("#c-body").innerHTML = fail("this page", "reload-route")); });
});
actions["save-coll"] = () => {
  if (!lastColl) return;
  const now = store.toggleSaved(lastColl);
  const b = $("#save-coll");
  if (b) b.textContent = now ? (lastColl.kind === "artist" ? "Following" : "In library") : (lastColl.kind === "artist" ? "Follow" : "Save to library");
  toast(now ? (lastColl.kind === "artist" ? "Following" : "Saved to library") : "Removed from library");
  refreshSide();
};

/* =============================== SETTINGS =============================== */
const SECTIONS = ["Playback", "Downloads", "For you", "Account", "Privacy", "Appearance", "About"];
const INTROS = [
  "Tune how songs sound and what plays next.", "Choose what is saved for listening without a connection.",
  "Make recommendations and charts fit you.", "Optional: connect your own YouTube Music account.", "Control what is saved on this device.",
  "Make the player look the way you like.", "App information and updates.",
];
let setSec = 0;
let curDefs = {};

const PLAYBACK = [["auto", "Auto"], ["stream", "Stream"], ["download", "Download first"]];
const METHODS = { stream: "Streamed directly", download: "Downloaded first", prefetch: "Fetched in advance", fallback: "Downloaded (stream was rejected)", offline: "Saved offline copy" };
function lastPlay() {
  const l = store.kv.get("lastPlay", null);
  const i = store.kv.get("lastPlayInfo", null);
  const more = i && (l?.m === "download" || l?.m === "prefetch" || l?.m === "fallback") ? ` · ${(i.size / 1048576).toFixed(1)} MB, plays ${Math.floor(i.got / 60)}:${String(Math.floor(i.got % 60)).padStart(2, "0")} of ${Math.floor(i.want / 60)}:${String(Math.floor(i.want % 60)).padStart(2, "0")}` : "";
  return l ? (METHODS[l.m] || l.m) + more : "Nothing played yet";
}
function settingsDefs() {
  const s = S.get(), t = S.getTaste();
  const plays = store.getSignals().length;
  const where = s.location === "auto" ? `Auto${S.autoRegion() ? " · " + S.regionName(S.autoRegion()) : ""}` : S.regionName(s.country);
  const summary = S.hasTaste() ? [t.languages.length && `${t.languages.length} language${t.languages.length > 1 ? "s" : ""}`, t.artists.length && `${t.artists.length} artist${t.artists.length > 1 ? "s" : ""}`].filter(Boolean).join(" · ") : "Choose";
  const sw = (id, label, desc, key, extra) => ({ id, k: "sw", t: label, d: desc, on: !!s[key], fn: () => { S.set({ [key]: !s[key] }); extra?.(); } });
  const Q = ["low", "high"];                                  // low to high, like the design
  const seg = (id, label, desc, key) => ({ id, k: "seg", t: label, d: desc, opts: Q.map((v) => ({ label: S.QUALITIES[v].label, v })), sel: Q.indexOf(s[key]), fn: (i) => S.set({ [key]: Q[i] }) });
  return [
    [ // Playback
      sw("autoplay", "Autoplay", "Keep playing similar songs when your queue ends.", "autoplay"),
      sw("dynamic", "Dynamic queue", "Get queue and radio updates based on your listening behavior", "dynamic"),
      sw("sb", "Skip non-music parts", "Uses SponsorBlock to jump over intros, outros and talking in music videos. Songs it has no data for play normally.", "sponsorBlock"),
      seg("quality", "Audio quality", "High is about 128 kbps (4 MB a song). Data saver is about 48 kbps (1.6 MB a song).", "quality"),
      { id: "pm", k: "seg", t: "How songs start", d: "Auto streams, and switches to download-first if your phone rejects streams. Stream starts fastest. Download first waits for the whole song, then plays it, and fetches the next song while you listen.",
        opts: PLAYBACK.map(([v, label]) => ({ label, v })), sel: PLAYBACK.findIndex(([v]) => v === (s.playback || "auto")), fn: (i) => S.set({ playback: PLAYBACK[i][0] }) },
    ],
    [ // Downloads
      seg("dlq", "Download quality", "Applies to new downloads. Songs already saved keep their quality.", "dlQuality"),
      sw("smart", "Smart downloads", "Automatically save songs you like for offline listening.", "smartDl"),
      { id: "manage", k: "btn", t: "Downloaded songs", d: "See what is saved and remove what you no longer need.", b: "Manage", act: "go-downloads" },
    ],
    [ // For you
      { id: "taste", k: "btn", t: "Improve your music recommendations", d: "Pick your music languages and some artists you like.", b: summary, act: "open-taste" },
      sw("global", "Global content", "Home, Quick picks, New releases, Trending and Charts show music from around the world. Turn it off to follow your location instead.", "global"),
      { id: "loc", k: "btn", t: "Location", d: s.global ? "Used when Global content is off. Uses your device's region, not GPS." : "Charts, new releases and search results follow this country. Uses your device's region, not GPS.", b: where, act: "open-location" },
    ],
    [ // Account
      ...(isNative() && getSource() === "device"
        ? signedIn()
          ? [
            { id: "yta", k: "val", t: "YouTube account", d: "Signed in on this phone. Your YouTube Music home and liked songs show on Home, and the account helps when YouTube asks the app to prove it isn't a bot.", v: accountName() || "Signed in" },
            { id: "ytout", k: "btn", t: "Sign out", d: "Forget the account on this phone and revoke its access.", b: "Sign out", act: "yt-signout" },
          ]
          : [{ id: "ytin", k: "btn", t: "Sign in with Google", d: "Optional and experimental. Shows your YouTube Music home and liked songs, and gives the app another way in when YouTube refuses to play for anonymous apps. You approve a short code on google.com/device; the app never sees your password.", b: "Sign in", act: "yt-signin" }]
        : [{ id: "ytna", k: "val", t: "YouTube account", d: "Sign-in works in the iPhone app with the music source set to This phone.", v: "Not available" }]),
    ],
    [ // Privacy
      sw("history", "Save listening history", "Use what you play to shape your recommendations.", "saveHistory"),
      { id: "backup", k: "btn", t: "Back up and restore", d: "Save your likes, playlists, genres, analytics and settings to a file, or bring them back from one.", b: "Open", act: "backup-open" },
      { id: "clearhist", k: "btn", t: "Listening history", d: "Remove what is saved on this device so far.", b: "Clear", fn: () => { store.clearHistory(); toast("Listening history cleared"); } },
      { id: "reset", k: "btn", t: "Queue learning", d: `Forget what ${APP_NAME} learned from your skips, likes and thumbs-down${plays ? ` (${plays} plays)` : ""}.`, b: "Reset", fn: () => { store.clearSignals(); localStorage.removeItem("dislikes"); toast("Queue learning reset"); } },
    ],
    [ // Appearance
      { id: "accent", k: "swatch", t: "Accent colour", d: "Used for progress, likes and selected items. Artwork follows each song's cover.",
        opts: [...S.ACCENTS.map(([c, label]) => ({ label, c })), { label: "Artwork", c: "art" }], sel: [...S.ACCENTS.map((a) => a[0]), "art"].indexOf(s.accent),
        fn: (i) => { const o = [...S.ACCENTS.map((a) => a[0]), "art"][i]; S.set({ accent: o }); applyAccent(); } },
      { id: "uinav", k: "seg", t: "Tab bar and mini player", d: "Glass floats them over your music with a frosted look. Classic docks them at the bottom.",
        opts: [{ label: "Classic" }, { label: "Glass" }], sel: s.uiNav === "classic" ? 0 : 1, fn: (i) => S.set({ uiNav: i ? "glass" : "classic" }) },
      { id: "uinp", k: "seg", t: "Now Playing", d: "Blur fills the screen with the cover and fades it into the controls. Classic shows a small cover on a soft background.",
        opts: [{ label: "Classic" }, { label: "Blur" }], sel: s.uiNp === "classic" ? 0 : 1, fn: (i) => S.set({ uiNp: i ? "blur" : "classic" }) },
      { id: "fit", k: "range", t: "Screen fit", d: "Drag to extend the app downward if there's an empty strip under the tab bar. If the tab bar disappears, drag back toward Auto.", v: S.get().bottomNudge || 0 },
    ],
    [ // About
      { id: "ver", k: "val", t: "Version", d: isNative() ? "The app build you are using." : "The build you are using.", v: "v" + APP_VERSION + (isNative() ? " (iPhone app)" : " (web)") },
      { id: "conn", k: "btn", t: isNative() ? "Music source" : "Access token", d: isNative() ? "Play straight from YouTube Music on this phone, or use your own PC server." : "The access token your backend asks for.", b: isNative() ? (getSource() === "device" ? "This phone" : getBase() ? new URL(getBase()).host : "Set up") : "Token", act: "open-connection" },
      ...(isNative() ? [] : [{ id: "upd", k: "btn", t: "Update app", d: "Fetch the latest version. Your saved songs, likes and settings are kept.", b: "Update", act: "app-update" }]),
      ...(isNative() ? [{ id: "netcheck", k: "btn", t: "Connection check", d: "Shows your phone's network addresses and whether YouTube accepts a test stream. Handy if songs don't start.", b: "Run", fn: async () => { toast("Checking…", 60000); toast(await checkConnection(), 40000); } }] : []),
      ...(isNative() ? [{ id: "netreset", k: "btn", t: "Reset connection", d: "Clears saved cookies and starts a fresh YouTube session. Try this if songs stop starting or only play for a minute.", b: "Reset", fn: async () => { toast(await resetConnection(), 6000); } }] : []),
      { id: "last", k: "val", t: "Last song played", d: "How the last song reached the player. Useful when a song is slow to start.", v: lastPlay() },
      { id: "disp", k: "val", t: "Display", d: "Screen and safe-area sizes, handy if something sits too high or low.", v: displayInfo() },
    ],
  ];
}
function displayInfo() {
  const probe = document.createElement("div");
  probe.style.cssText = "position:fixed;visibility:hidden;padding-top:env(safe-area-inset-top);padding-bottom:env(safe-area-inset-bottom)";
  document.body.appendChild(probe);
  const cs = getComputedStyle(probe), top = parseInt(cs.paddingTop) || 0, bottom = parseInt(cs.paddingBottom) || 0;
  probe.remove();
  const fixed = getComputedStyle(document.documentElement).getPropertyValue("--app-h").trim(), vv = window.visualViewport;
  const app = document.querySelector("#app")?.getBoundingClientRect();
  return `window ${innerWidth}×${innerHeight}${fixed ? " → " + fixed : ""} · visual ${vv ? Math.round(vv.width) + "×" + Math.round(vv.height) + " @" + Math.round(vv.offsetTop) : "n/a"} · screen ${screen.width}×${screen.height} · safe ${top}/${bottom} · app ${app ? Math.round(app.top) + "–" + Math.round(app.bottom) : "n/a"} · mode ${navigator.standalone ? "home-screen" : "browser"}`;
}
register("settings", () => {
  const defs = settingsDefs(); curDefs = {};
  const items = defs[setSec].map((x) => { curDefs[x.id] = x; return x; });
  const row = (x) => {
    let ctl = "";
    if (x.k === "sw") ctl = `<button class="switch${x.on ? " on" : ""}" role="switch" aria-checked="${x.on}" aria-label="${esc(x.t)}" data-act="set-item" data-id="${x.id}"><i></i></button>`;
    else if (x.k === "seg") ctl = `<div class="seg" role="group" aria-label="${esc(x.t)}">${x.opts.map((o, i) => `<button class="${x.sel === i ? "on" : ""}" aria-pressed="${x.sel === i}" data-act="set-item" data-id="${x.id}" data-opt="${i}">${o.label}</button>`).join("")}</div>`;
    else if (x.k === "swatch") ctl = `<div class="swatches" role="group" aria-label="${esc(x.t)}">${x.opts.map((o, i) => `<button class="${x.sel === i ? "on" : ""}" aria-label="${o.label}" aria-pressed="${x.sel === i}" data-act="set-item" data-id="${x.id}" data-opt="${i}"><i style="background:${o.c === "art" ? "conic-gradient(#ff6a3d,#f5c542,#2dd4a7,#7c8cff,#ff6a3d)" : o.c}"></i></button>`).join("")}</div>`;
    else if (x.k === "btn") ctl = `<button class="set-btn" data-act="${x.act || "set-item"}" data-id="${x.id}">${esc(x.b)}</button>`;
    else if (x.k === "val") ctl = `<span class="set-val">${esc(x.v)}</span>`;
    else if (x.k === "range") ctl = `<div class="fit"><input type="range" class="rg" id="fit-range" min="0" max="100" step="1" value="${x.v}" style="--p:${x.v}%" aria-label="${esc(x.t)}"><span class="set-val" id="fit-val">${x.v ? "+" + x.v + " px" : "Auto"}</span></div>`;
    return `<div class="set-row"><div class="t"><b>${esc(x.t)}</b><span>${esc(x.d)}</span></div>${ctl}</div>`;
  };
  page(hdrBack("Settings"), `
    <div class="chips-row tight hs" role="tablist" aria-label="Settings sections">${SECTIONS.map((n, i) => `<button class="chip${setSec === i ? " on" : ""}" role="tab" aria-selected="${setSec === i}" data-act="set-sec" data-i="${i}">${n}</button>`).join("")}</div>
    <p class="set-intro">${INTROS[setSec]}</p>
    <div class="set-list">${items.map(row).join("")}</div>`);
});
actions["set-sec"] = (el) => { setSec = Number(el.dataset.i); rerender(); };
actions["set-item"] = (el) => {
  const x = curDefs[el.dataset.id]; if (!x?.fn) return;
  x.fn(el.dataset.opt !== undefined ? Number(el.dataset.opt) : undefined);
  rerender();
};
actions["open-settings"] = () => navigate({ name: "settings" });
actions["open-taste"] = () => navigate({ name: "taste" });
actions["go-downloads"] = () => setTab("downloads");

/* =============================== TASTE: languages + artists =============================== */
let tasteQ = "", tasteT;
register("taste", () => {
  const t = S.getTaste();
  page(hdrBack("Your taste"), `
    <p class="set-intro">Pick what you like. Home and your queue use this. It stays on this device.</p>
    <div class="sec-head" style="margin-top:16px"><h2 class="h2" style="font-size:20px">Languages</h2><span class="cap" id="t-lcount" style="margin:0">${t.languages.length} picked</span></div>
    <div class="chips-wrap" role="group" aria-label="Music languages">${S.LANGUAGES.map((l) => `<button class="chip${t.languages.includes(l) ? " on" : ""}" data-act="taste-lang" data-v="${l}" aria-pressed="${t.languages.includes(l)}">${l}</button>`).join("")}</div>
    <div class="sec-head" style="margin-top:24px"><h2 class="h2" style="font-size:20px">Artists</h2><span class="cap" id="t-count" style="margin:0">${t.artists.length} picked</span></div>
    <div id="t-picked">${pickedHtml()}</div>
    <div style="padding:0 var(--gx) 14px"><div class="sbox">${ic("search", 20)}<input id="t-q" type="search" placeholder="Search for an artist" autocomplete="off" autocapitalize="off" spellcheck="false" aria-label="Search for an artist" value="${esc(tasteQ)}"></div></div>
    <div id="t-body"></div>`);
  const q = $("#t-q");
  q.addEventListener("input", () => { tasteQ = q.value; clearTimeout(tasteT); tasteT = setTimeout(loadTasteBody, 280); });
  loadTasteBody();
});
const pickedHtml = () => {
  const a = S.getTaste().artists;
  return a.length ? `<div class="avrow">${a.map((x) => `<button class="av" data-act="taste-artist" data-id="${esc(x.browseId)}" aria-label="Remove ${esc(x.name)}"><img src="${art(x.thumbnail, 120)}" alt="">${esc(x.name)}${ic("close", 16)}</button>`).join("")}</div>` : '<p class="note" style="padding-top:0">None yet. Search below or tap a suggestion.</p>';
};
async function loadTasteBody() {
  const body = $("#t-body"); if (!body) return;
  const q = tasteQ.trim();
  body.innerHTML = `<div class="avgrid">${'<div class="sk" style="aspect-ratio:1;border-radius:50%"></div>'.repeat(6)}</div>`;
  try {
    const items = q ? await api(`/api/artists/search?q=${encodeURIComponent(q)}`) : (await api(`/api/charts?country=${S.loc() || "ZZ"}`)).artists.slice(0, 24);
    if (getCur() !== "taste" || tasteQ.trim() !== q) return;
    items.forEach((a) => artistReg.set(a.id, a));
    const picked = new Set(S.getTaste().artists.map((a) => a.browseId));
    body.innerHTML = (q ? "" : `<div class="tiles-h" style="margin-top:0">Popular${S.loc() ? " in " + esc(S.regionName(S.loc())) : ""}</div>`) +
      (items.length ? `<div class="avgrid">${items.map((a) => `
        <button class="avc${picked.has(a.id) ? " on" : ""}" data-act="taste-artist" data-id="${esc(a.id)}" aria-pressed="${picked.has(a.id)}">
          <span class="pic"><img loading="lazy" src="${art(a.thumbnail, 200)}" alt=""><i>${ic("check", 34, { sw: 2.6 })}</i></span><b>${esc(a.title)}</b>
        </button>`).join("")}</div>` : '<p class="note">No artists found.</p>');
  } catch { body.innerHTML = fail("artists", "reload-route"); }
}
actions["taste-lang"] = (el) => {
  const v = el.dataset.v, cur = S.getTaste().languages;
  S.setTaste({ languages: cur.includes(v) ? cur.filter((x) => x !== v) : [...cur, v] });
  el.classList.toggle("on"); el.setAttribute("aria-pressed", el.classList.contains("on"));
  $("#t-lcount").textContent = `${S.getTaste().languages.length} picked`;
};
actions["taste-artist"] = (el) => {
  const id = el.dataset.id, list = S.getTaste().artists, a = artistReg.get(id);
  S.setTaste({ artists: list.some((x) => x.browseId === id) ? list.filter((x) => x.browseId !== id) : (a ? [...list, { browseId: id, name: a.title || a.name, thumbnail: a.thumbnail }] : list) });
  const picked = new Set(S.getTaste().artists.map((x) => x.browseId));
  $("#t-picked").innerHTML = pickedHtml();
  $("#t-count").textContent = `${picked.size} picked`;
  $$(".avc").forEach((b) => { const on = picked.has(b.dataset.id); b.classList.toggle("on", on); b.setAttribute("aria-pressed", on); });
};

/* =============================== chrome: bottom tabs + desktop sidebar =============================== */
const TABS = [["home", "Home", "home"], ["mix", "Mix", "radio"], ["explore", "Explore", "explore"], ["library", "Library", "library"], ["stats", "Analytics", "chart"]];
export function buildChrome() {
  $("#tabs").innerHTML = TABS.map(([id, label, icon]) => `<button data-tab="${id}" data-act="tab" aria-label="${label}">${ic(icon, 24)}${label}</button>`).join("");
  $("#gsearch").innerHTML = ic("search", 26);
  refreshSide();
}
export function refreshSide() {
  const side = $("#side"); if (!side) return;
  const nav = (id, label, icon) => `<button class="navb" data-tab="${id}" data-act="tab">${ic(icon, 22)}${label}</button>`;
  const pls = store.getPlaylists();
  side.innerHTML = `
    ${nav("home", "Home", "home")}${nav("mix", "Mix", "radio")}${nav("explore", "Explore", "explore")}${nav("library", "Library", "library")}${nav("stats", "Analytics", "chart")}
    <hr>
    <button class="navb newpl" data-act="new-playlist">${ic("plus", 18, { sw: 2 })}New playlist</button>
    <div style="height:12px"></div>
    <button class="navb pl" data-act="open-local" data-id="liked"><span class="cv" style="background:linear-gradient(135deg,#6d5bd0,#d6c8ff);display:block"></span><span>Liked music</span></button>
    ${pls.map((p) => `<button class="navb pl" data-act="open-local" data-id="${esc(p.id)}">${p.tracks[0]?.thumbnail ? cover(p.tracks[0].thumbnail, "", p.name, 80) : `<span class="cv" style="background:${gradient(p.name)};display:block"></span>`}<span>${esc(p.name)}</span></button>`).join("")}
    <button class="navb pl" data-tab="downloads" data-act="tab"><span class="cv" style="background:var(--line2);display:grid;place-items:center;color:var(--soft)">${ic("download", 16)}</span><span>Downloads</span></button>`;
  const cur = document.querySelector("#tabs button.on")?.dataset.tab;
  if (cur) $$(`#side .navb[data-tab="${cur}"]`).forEach((b) => b.classList.add("on"));
}
actions["tab"] = (el) => { setTab(el.dataset.tab); };
