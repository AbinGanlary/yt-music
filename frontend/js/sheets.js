// Bottom sheets: song menu, playlists, location, Save to Files, ringtone maker. Also offline saving and sharing.
import { api, art, fmtTime, isNative, getBase, getToken, getSource, setSource, setConnection, testConnection, testDevice } from "./api.js";
import * as store from "./store.js";
import * as P from "./player.js";
import * as S from "./settings.js";
import { ic } from "./icons.js";
import { $, $$, esc, toast, sub, cover } from "./ui.js";
import { navigate, rerender, getCur, back, setTab } from "./nav.js";
import { refreshSide } from "./views.js";

export const actions = {};
let menuT = null, menuCtx = "";
const sheet = $("#sheet"), body = $("#sheet-body");
const open = (html) => { body.innerHTML = html; sheet.hidden = false; };
export const openSheet = open;
export const closeSheet = () => { sheet.hidden = true; };
const ping = (name, detail) => document.dispatchEvent(new CustomEvent(name, { detail }));
const mb = (n) => (n / 1048576).toFixed(1) + " MB";
const head = (t) => `<div class="sheet-head">${cover(t.thumbnail, "", t.title)}<div style="min-width:0"><b>${esc(t.title)}</b><span>${esc(sub(t))}</span></div></div>`;
const fileBase = (t) => `${t.title}${t.artists?.[0] ? " - " + t.artists[0] : ""}`.replace(/[\\/:*?"<>|\u0000-\u001f]/g, "").trim().slice(0, 90) || "song";
const refreshLists = () => { refreshSide(); if (["library", "local", "downloads"].includes(getCur())) rerender(); };

/* ---------------- offline saving ---------------- */
const busy = new Set();
export async function saveOffline(t, quiet = false) {
  if (busy.has(t.videoId) || store.downloadedIds.has(t.videoId)) return;
  busy.add(t.videoId);
  if (!quiet) toast(`Saving “${t.title}”…`);
  try {
    await store.download(t, (p) => ping("dl-progress", { id: t.videoId, p }));
    if (!quiet) toast("Saved for offline");
  } catch { toast("Download failed"); }
  busy.delete(t.videoId);
  ping("dl-progress", { id: t.videoId, p: -1 });
  ping("marks");
  if (getCur() === "downloads" || getCur() === "library") rerender();
}
export const isSaving = (id) => busy.has(id);

/** Toggle like; with Smart downloads on, a newly liked song is also saved offline. */
export function toggleLike(t) {
  const now = store.toggleLike(t);
  toast(now ? "Added to liked" : "Removed from liked");
  if (now && S.get().smartDl) saveOffline(t, true);
  ping("marks");
  if (["library", "local"].includes(getCur())) rerender();
  return now;
}

/* ---------------- sharing + exporting ---------------- */
function fallbackDownload(blob, name) {
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob); a.download = name;
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 60000);
  toast("Downloading…");
}
// iOS only allows the share sheet right after a tap, so each flow prepares the file first,
// then shows a button whose handler calls share() with nothing awaited before it.
let pending = null;                                      // { blob, name }
function shareFile(blob, name) {
  const file = new File([blob], name, { type: blob.type || "audio/mp4" });
  if (navigator.canShare?.({ files: [file] })) navigator.share({ files: [file], title: name }).catch((e) => { if (e.name !== "AbortError") fallbackDownload(blob, name); });
  else fallbackDownload(blob, name);
}
export const shareBlob = shareFile;
async function shareLink(t) {
  const url = `https://music.youtube.com/watch?v=${t.videoId}`;
  const data = { title: t.title, text: `${t.title} — ${sub(t)}`, url };
  try {
    if (navigator.share) await navigator.share(data);
    else { await navigator.clipboard.writeText(url); toast("Link copied"); }
  } catch (e) { if (e.name !== "AbortError") { try { await navigator.clipboard.writeText(url); toast("Link copied"); } catch {} } }
}

export function openExport(t) {
  pending = null; menuT = t;
  open(`<div class="sheet-title">Save to Files</div>${head(t)}
    <div class="sheet-pad"><p class="note" id="x-msg" style="padding:8px 0">Preparing the file…</p>
    <button class="btn wide" id="x-go" data-act="x-share" hidden>Save to Files</button>
    <p class="fine">Pick <b>On My iPhone → Downloads</b> (or any folder) on the next screen. The file is an .m4a audio file.</p>
    <button class="mitem" data-act="s-ringtone" style="margin-top:8px">${ic("bell", 22)}<span>Make a ringtone from this song</span></button></div>`);
  store.songBlob(t, (p) => { const m = $("#x-msg"); if (m) m.textContent = `Preparing… ${Math.round(p * 100)}%`; }).then((blob) => {
    pending = { blob, name: `${fileBase(t)}.m4a` };
    if ($("#x-msg")) { $("#x-msg").textContent = `Ready · ${mb(blob.size)}`; $("#x-go").hidden = false; }
  }).catch(() => { if ($("#x-msg")) $("#x-msg").textContent = "Couldn't get the audio. Check the connection and try again."; });
}

const rt = { t: null, start: 0, dur: 30, total: 240 };
function rtTotal(t) {
  if (P.current()?.videoId === t.videoId && isFinite(P.audio.duration)) return P.audio.duration;
  const m = /^(\d+):(\d{2})$/.exec(t.duration || "");
  return m ? Number(m[1]) * 60 + Number(m[2]) : 240;
}
export function openRingtone(t) {
  pending = null;
  const isCur = P.current()?.videoId === t.videoId;
  rt.t = t; rt.total = rtTotal(t); rt.dur = 30;
  rt.start = Math.max(0, Math.min(isCur ? Math.floor(P.audio.currentTime) : Math.floor(rt.total * 0.25), rt.total - rt.dur));
  open(`<div class="sheet-title">Make a ringtone</div>${head(t)}
    <div class="sheet-pad">
    <div class="rt-row"><span>Starts at</span><b id="rt-start"></b>${isCur ? '<button class="chip" data-act="rt-here">Use current position</button>' : ""}</div>
    <input type="range" class="rg" id="rt-range" min="0" step="1" value="0" aria-label="Clip start">
    <div class="rt-row"><span>Length</span><div style="display:flex;gap:8px;margin-left:auto">${[15, 20, 30].map((d) => `<button class="chip${rt.dur === d ? " on" : ""}" style="height:32px;padding:0 12px" data-act="rt-dur" data-d="${d}">${d} s</button>`).join("")}</div></div>
    <div class="rt-actions">${isCur ? '<button class="btn ghost" data-act="rt-preview">Preview</button>' : ""}<button class="btn" id="rt-go" data-act="rt-make">Create ringtone</button></div>
    <p class="note" id="rt-msg" style="padding:8px 0 0">${isCur ? "Tip: play the song and tap “Use current position” to pick the exact start." : ""}</p>
    <details class="rt-help"><summary>How to make it your ringtone on iPhone</summary><ol>
      <li>Tap <b>Save to Files</b> and keep the clip somewhere you can find it.</li>
      <li>Open <b>GarageBand</b> (free in the App Store), start a new project with any <i>Audio Recorder</i>, and switch to the <b>tracks</b> view.</li>
      <li>Tap <b>+</b> / the loop button → <b>Files</b> → <b>Browse items from the Files app</b>, pick the clip, and drag it into the track.</li>
      <li>Go back to <b>My Songs</b>, touch and hold the project → <b>Share → Ringtone → Export</b>.</li>
      <li>Tap <b>Use sound as…</b> → <b>Standard Ringtone</b> (or set it later in <b>Settings → Sounds &amp; Haptics → Ringtone</b>).</li>
    </ol><p class="fine">Steps vary a little between iOS versions. iPhone ringtones can be at most 40 seconds, and GarageBand keeps them to 30.</p></details></div>`);
  rtPaint(true);
}
function rtPaint(init) {
  const range = $("#rt-range"); if (!range) return;
  range.max = Math.max(0, Math.floor(rt.total - rt.dur));
  rt.start = Math.min(rt.start, Number(range.max));
  if (init || Number(range.value) !== rt.start) range.value = rt.start;
  range.style.setProperty("--p", (range.max > 0 ? (rt.start / range.max) * 100 : 0) + "%");
  $("#rt-start").textContent = `${fmtTime(rt.start)} – ${fmtTime(Math.min(rt.total, rt.start + rt.dur))}`;
}
function rtInvalidate() {
  pending = null;
  const go = $("#rt-go"); if (go) { go.dataset.act = "rt-make"; go.textContent = "Create ringtone"; go.disabled = false; }
  const m = $("#rt-msg"); if (m) m.textContent = "";
}
export function rtRange(value) { rt.start = Number(value); rtPaint(); rtInvalidate(); }
let previewT;

/* ---------------- playlists ---------------- */
let newPlCb = null;
function openNewPlaylist(cb = null) {
  newPlCb = cb;
  open(`<div class="sheet-title">New playlist</div><div class="sheet-pad"><input class="field" id="pl-name" placeholder="Playlist name" maxlength="60" autocomplete="off" aria-label="Playlist name"><button class="btn wide" style="margin-top:12px" data-act="pl-create">Create</button>${cb ? "" : `<button class="btn wide ghost" style="margin-top:10px" data-act="pl-import">Import songs from a list…</button>`}</div>`);
  setTimeout(() => $("#pl-name")?.focus(), 80);
}
function openSaveToPlaylist(t) {
  const pls = store.getPlaylists();
  open(`<div class="sheet-title">Save to playlist</div>
    <button class="mitem" data-act="pl-new-with">${ic("plus", 22, { sw: 2 })}<span>New playlist</span></button>
    ${pls.map((p) => `<button class="mitem" data-act="pl-add" data-id="${esc(p.id)}">${p.tracks[0]?.thumbnail ? cover(p.tracks[0].thumbnail, "sm", p.name, 80) : `<span class="cv sm mosaic" style="background:var(--line2)">${esc(p.name.charAt(0).toUpperCase())}</span>`}<span style="min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esc(p.name)}</span><small>${p.tracks.length} songs${p.tracks.some((x) => x.videoId === t.videoId) ? " · added" : ""}</small></button>`).join("")}`);
}

/* ---------------- connection (music source, server address, access token) ---------------- */
let connSrc = "device";
export function openConnection(reason = "") {
  const native = isNative();
  connSrc = native ? getSource() : "server";
  const label = (id, text) => `<label for="${id}" class="fine" style="margin:10px 0 6px;display:block" id="${id}-l">${text}</label>`;
  open(`<div class="sheet-title">${native ? "Music source" : "Access token"}</div><div class="sheet-pad">
    ${native ? `<div class="seg" role="group" aria-label="Music source" style="margin:4px 0 4px;width:100%"><button class="${connSrc === "device" ? "on" : ""}" style="flex:1" data-act="conn-src" data-v="device">This phone</button><button class="${connSrc === "server" ? "on" : ""}" style="flex:1" data-act="conn-src" data-v="server">My server</button></div>` : ""}
    <p class="note" id="conn-intro" style="padding:8px 0 0"></p>
    <div id="conn-server-box" ${native ? "" : "hidden"}>${label("conn-server", "Server address")}<input class="field" id="conn-server" type="url" inputmode="url" autocapitalize="off" autocorrect="off" spellcheck="false" placeholder="https://your-pc.your-tailnet.ts.net" value="${esc(getBase())}"></div>
    <div id="conn-token-box">${label("conn-token", "Access token")}<input class="field" id="conn-token" type="password" autocapitalize="off" autocorrect="off" spellcheck="false" autocomplete="off" placeholder="Paste your access token" value="${esc(getToken())}"></div>
    <p class="note" id="conn-msg" style="padding:10px 0 0">${reason === "token" ? "The server needs your access token." : ""}</p>
    <button class="btn wide" id="conn-go" data-act="conn-save" style="margin-top:6px">Save</button></div>`);
  paintConn();
}
function paintConn() {
  const dev = connSrc === "device", native = isNative();
  const intro = !native ? "This site is served by your backend. Enter the access token if it asks for one."
    : dev ? "Search and play straight from YouTube Music on this phone. No PC or Tailscale needed. A server is only used for ringtone clips (optional)."
    : "Use your own PC server over Tailscale. Enter its HTTPS address and your access token.";
  $("#conn-intro").textContent = intro;
  $("#conn-server-box").hidden = !native;
  $("#conn-token-box").hidden = native && dev && !($("#conn-server")?.value || "").trim();
  const l = $("#conn-server-l"); if (l) l.textContent = dev ? "Server address (optional, for ringtone clips)" : "Server address";
}
actions["open-connection"] = () => openConnection();
actions["conn-src"] = (el) => {
  connSrc = el.dataset.v;
  $$("[data-act=conn-src]").forEach((b) => b.classList.toggle("on", b.dataset.v === connSrc));
  paintConn();
};
actions["conn-save"] = async () => {
  const go = $("#conn-go"), msg = $("#conn-msg"), native = isNative();
  const server = native ? ($("#conn-server")?.value || "").trim() : "";
  const tokenVal = ($("#conn-token")?.value || "").trim();
  const useDevice = native && connSrc === "device";
  if (native && (server || !useDevice) && !/^https?:\/\//i.test(server)) { msg.textContent = "Start the address with https:// (for example https://your-pc.your-tailnet.ts.net)."; return; }
  go.disabled = true; go.textContent = "Checking…"; msg.textContent = "";
  let r = { ok: true };
  if (useDevice) { r = await testDevice(); if (r.ok && server) r = await testConnection(server, tokenVal); }
  else r = await testConnection(server, tokenVal);
  go.disabled = false; go.textContent = "Save";
  if (!r.ok) { msg.textContent = r.reason; return; }
  if (native) setSource(useDevice ? "device" : "server");
  setConnection({ server: native ? server : undefined, token: tokenVal });
  closeSheet(); toast(useDevice ? "Using this phone" : "Connected");
  ping("connected");
};

/* ---------------- location ---------------- */
let countryCodes = null;
async function openLocation() {
  open(`<div class="sheet-title">Location</div><div class="sheet-pad"><input id="loc-q" class="field" type="search" placeholder="Search countries" autocomplete="off" aria-label="Search countries"><div id="loc-list" class="loc-list"><p class="note">Loading…</p></div></div>`);
  try { countryCodes ??= await api("/api/countries"); } catch { $("#loc-list").innerHTML = '<p class="note">Couldn\'t load countries.</p>'; return; }
  drawLocations("");
}
export function drawLocations(filter) {
  if (!countryCodes) return;
  const s = S.get(), f = filter.trim().toLowerCase(), auto = S.autoRegion();
  const items = countryCodes.map((c) => ({ c, n: S.regionName(c) })).filter((x) => !f || x.n.toLowerCase().includes(f)).sort((a, b) => a.n.localeCompare(b.n));
  const li = (v, label, on, small = "") => `<button class="loc-item${on ? " on" : ""}" data-act="loc-pick" data-v="${v}"><span>${esc(label)}${small ? `<small>${esc(small)}</small>` : ""}</span>${on ? ic("check", 20, { sw: 2.4 }) : ""}</button>`;
  $("#loc-list").innerHTML = (f ? "" : li("auto", "Auto", s.location === "auto", auto ? S.regionName(auto) : "device region unknown")) + items.map((x) => li(x.c, x.n, s.location !== "auto" && s.country === x.c)).join("") || '<p class="note">No match.</p>';
}

/* ---------------- the song menu ---------------- */
export function openMenu(t, ctx = "") {
  menuT = t; menuCtx = ctx;
  const liked = store.isLiked(t.videoId), saved = store.downloadedIds.has(t.videoId);
  const it = (act, icon, label, cls = "", extra = "", o = {}) => `<button class="mitem ${cls}" role="menuitem" data-act="${act}"${extra}>${ic(icon, 22, o)}<span>${label}</span></button>`;
  open(`${head(t)}
    ${it("s-radio", "radio", "Start radio")}
    ${it("s-next", "next", "Play next")}
    ${it("s-queue", "queueAdd", "Add to queue")}
    ${it("s-playlist", "playlistAdd", "Save to playlist")}
    ${saved ? it("s-undl", "trash", "Remove download", "danger") : it("s-dl", "download", "Download")}
    ${it("s-share", "share", "Share")}
    ${t.albumId ? it("s-album", "album", "Go to album", "", ` data-aid="${esc(t.albumId)}"`) : ""}
    ${t.artistIds?.[0] ? it("s-artist", "artist", "Go to artist", "", ` data-aid="${esc(t.artistIds[0])}"`) : ""}
    ${it("s-like", "thumb", liked ? "Remove from liked" : "Like", "", "", { fill: liked })}
    ${it("s-export", "file", "Save to Files")}
    ${it("s-ringtone", "bell", "Make ringtone")}
    ${ctx.startsWith("pl:") ? it("s-rmpl", "trash", "Remove from this playlist", "danger") : ""}`);
}

/* ---------------- actions ---------------- */
actions["sheet-close"] = closeSheet;
actions["s-radio"] = () => { P.startRadio(menuT); toast("Starting radio"); closeSheet(); };
actions["s-next"] = () => { P.playNext(menuT); toast("Plays next"); closeSheet(); };
actions["s-queue"] = () => { P.addToQueue(menuT); toast("Added to queue"); closeSheet(); };
actions["s-playlist"] = () => openSaveToPlaylist(menuT);
actions["s-dl"] = () => { closeSheet(); saveOffline(menuT); };
actions["s-undl"] = () => { const id = menuT.videoId; closeSheet(); store.delDownload(id).then(() => { toast("Removed download"); ping("marks"); refreshLists(); }); };
actions["s-share"] = () => { closeSheet(); shareLink(menuT); };
actions["s-album"] = (el) => { closeSheet(); ping("close-np"); navigate({ name: "collection", kind: "album", id: el.dataset.aid }); };
actions["s-artist"] = (el) => { closeSheet(); ping("close-np"); navigate({ name: "collection", kind: "artist", id: el.dataset.aid }); };
actions["s-like"] = () => { toggleLike(menuT); closeSheet(); };
actions["s-export"] = () => openExport(menuT);
actions["s-ringtone"] = () => openRingtone(menuT);
actions["s-rmpl"] = () => { store.removeFromPlaylist(menuCtx.slice(3), menuT.videoId); closeSheet(); toast("Removed from playlist"); refreshLists(); };
actions["x-share"] = () => { if (pending) shareFile(pending.blob, pending.name); };     // nothing awaited before share(): keeps the tap's permission
actions["rt-here"] = () => { if (P.current()?.videoId === rt.t.videoId) { rt.start = Math.floor(P.audio.currentTime); rtPaint(); rtInvalidate(); } };
actions["rt-dur"] = (el) => { rt.dur = Number(el.dataset.d); $$("[data-act=rt-dur]").forEach((c) => c.classList.toggle("on", c === el)); rtPaint(); rtInvalidate(); };
actions["rt-preview"] = () => {
  if (P.current()?.videoId !== rt.t.videoId) return;
  clearTimeout(previewT);
  P.seek(rt.start); if (P.audio.paused) P.toggle();
  previewT = setTimeout(() => { if (!P.audio.paused) P.toggle(); }, rt.dur * 1000);
};
actions["rt-make"] = async () => {
  const go = $("#rt-go"), msg = $("#rt-msg");
  go.disabled = true; go.textContent = "Cutting…"; msg.textContent = "";
  try {
    const blob = await store.ringtoneBlob(rt.t, rt.start, rt.dur);
    pending = { blob, name: `${fileBase(rt.t)} (ringtone).m4a` };
    go.disabled = false; go.dataset.act = "x-share"; go.textContent = "Save to Files";
    msg.textContent = `Ready · ${rt.dur} s clip · ${mb(blob.size)}`;
  } catch (e) {
    go.disabled = false; go.textContent = "Create ringtone";
    msg.textContent = e && e.message === "needs-server" ? "Ringtone clips are cut on your PC server. Add it under Settings → About → Server connection." : "Couldn't make the clip. Is the PC backend reachable?";
  }
};
actions["new-playlist"] = () => openNewPlaylist();
actions["pl-new-with"] = () => { const t = menuT; openNewPlaylist((id, name) => { store.addToPlaylist(id, t); toast(`Saved to ${name}`); }); };
actions["pl-create"] = () => {
  const name = ($("#pl-name")?.value || "").trim() || "New playlist";
  const id = store.createPlaylist(name);
  closeSheet();
  if (newPlCb) newPlCb(id, name); else toast(`Created “${name}”`);
  newPlCb = null; refreshLists();
};
actions["pl-add"] = (el) => {
  const p = store.getPlaylist(el.dataset.id);
  const added = store.addToPlaylist(el.dataset.id, menuT);
  closeSheet(); toast(added ? `Saved to ${p?.name}` : `Already in ${p?.name}`); refreshLists();
};
actions["pl-rename"] = (el) => {
  const p = store.getPlaylist(el.dataset.id); if (!p) return;
  open(`<div class="sheet-title">Rename playlist</div><div class="sheet-pad"><input class="field" id="pl-name" value="${esc(p.name)}" maxlength="60" autocomplete="off" aria-label="Playlist name"><button class="btn wide" style="margin-top:12px" data-act="pl-rename-do" data-id="${esc(p.id)}">Save</button></div>`);
  setTimeout(() => { const i = $("#pl-name"); i?.focus(); i?.select(); }, 80);
};
actions["pl-rename-do"] = (el) => { store.renamePlaylist(el.dataset.id, $("#pl-name").value); closeSheet(); toast("Renamed"); refreshLists(); };
actions["pl-delete"] = (el) => {
  const p = store.getPlaylist(el.dataset.id); if (!p) return;
  open(`<div class="sheet-title">Delete “${esc(p.name)}”?</div><div class="sheet-pad"><p class="note" style="padding:0 0 12px">This removes the playlist. The songs stay in your library and on your device.</p><button class="btn wide" style="background:#ff8a78;margin-bottom:10px" data-act="pl-delete-do" data-id="${esc(p.id)}">Delete playlist</button><button class="btn wide ghost" data-act="sheet-close">Cancel</button></div>`);
};
actions["pl-delete-do"] = (el) => { store.deletePlaylist(el.dataset.id); closeSheet(); toast("Playlist deleted"); refreshSide(); setTab("library"); };
actions["open-location"] = openLocation;
actions["loc-pick"] = (el) => {
  const v = el.dataset.v;
  S.set(v === "auto" ? { location: "auto" } : { location: "manual", country: v });
  closeSheet(); toast(`Location: ${v === "auto" ? "Auto" : S.regionName(v)}`);
  ping("location-changed"); rerender();
};
