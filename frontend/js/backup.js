// Back up and restore what lives on this device, and import a playlist from a pasted list or CSV.
import { api } from "./api.js";
import * as store from "./store.js";
import { ic } from "./icons.js";
import { $, esc, toast } from "./ui.js";
import { navigate, getCur, rerender } from "./nav.js";
import { openSheet, closeSheet, shareBlob } from "./sheets.js";
import { refreshSide } from "./views.js";

export const actions = {};

/* ============================ backup ============================ */
// What is saved: likes, playlists, saved albums and artists, genres, listening stats, history, settings and taste.
// Not saved: the songs downloaded for offline (they are audio files; download them again), and the server token.
const KEYS = ["likes", "dislikes", "history", "recent", "genres", "library", "settings", "taste", "stats", "signals"];

actions["backup-open"] = () => {
  openSheet(`<div class="sheet-title">Back up and restore</div><div class="sheet-pad">
    <p class="note" style="padding:0 0 12px">Save your likes, playlists, saved albums and artists, genres, listening stats and settings to a file, and bring them back on another phone or after reinstalling. Songs saved for offline aren't included.</p>
    <button class="btn wide" data-act="backup-export">${ic("share", 18)}Back up to a file</button>
    <label class="btn wide ghost" style="margin-top:10px;display:flex;justify-content:center;gap:8px;cursor:pointer">${ic("download", 18)}Restore from a file<input id="bk-file" type="file" accept=".json,application/json" hidden></label>
    <p class="fine" id="bk-msg"></p></div>`);
};

actions["backup-export"] = () => {
  const data = {};
  for (const k of KEYS) { const v = localStorage.getItem(k); if (v != null) data[k] = v; }
  const file = { app: "yt-music", version: 1, at: new Date().toISOString(), data };
  const blob = new Blob([JSON.stringify(file)], { type: "application/json" });
  shareBlob(blob, `YT-Music-backup-${new Date().toISOString().slice(0, 10)}.json`);     // nothing awaited before this: iOS needs the tap
};

document.addEventListener("change", async (e) => {
  if (e.target.id !== "bk-file" || !e.target.files?.[0]) return;
  const msg = $("#bk-msg");
  try {
    const file = JSON.parse(await e.target.files[0].text());
    if (file?.app !== "yt-music" || !file.data) throw new Error("not a backup");
    const r = restore(file.data);
    if (msg) msg.textContent = `Restored: ${r.join(", ")}. Reloading…`;
    toast("Backup restored");
    setTimeout(() => location.reload(), 900);
  } catch { if (msg) msg.textContent = "That file isn't a YT Music backup."; }
});

const parse = (raw, d) => { try { return JSON.parse(raw) ?? d; } catch { return d; } };
const union = (a, b, key) => { const seen = new Set(a.map(key)); return a.concat(b.filter((x) => !seen.has(key(x)))); };
/** Merge a backup into what is on this device: lists are combined, settings come from the backup. */
function restore(data) {
  const done = [], put = (k, v) => localStorage.setItem(k, JSON.stringify(v));
  for (const k of ["likes", "dislikes", "history", "signals"]) {
    if (data[k] == null) continue;
    const cur = parse(localStorage.getItem(k), []), inc = parse(data[k], []);
    put(k, union(cur, inc, k === "signals" ? (x) => x.at : (x) => x.videoId));
    if (k === "likes") done.push(`${inc.length} likes`);
  }
  if (data.recent != null) put("recent", union(parse(localStorage.getItem("recent"), []), parse(data.recent, []), (x) => x));
  if (data.genres != null) { put("genres", union(parse(localStorage.getItem("genres"), []), parse(data.genres, []), (x) => x.id)); done.push("genres"); }
  if (data.library != null) {
    const cur = parse(localStorage.getItem("library"), { playlists: [], saved: [] }), inc = parse(data.library, { playlists: [], saved: [] });
    put("library", { playlists: union(cur.playlists || [], inc.playlists || [], (x) => x.id), saved: union(cur.saved || [], inc.saved || [], (x) => x.kind + x.id) });
    done.push(`${(inc.playlists || []).length} playlists`);
  }
  if (data.stats != null) {
    const cur = parse(localStorage.getItem("stats"), { log: [], meta: {} }), inc = parse(data.stats, { log: [], meta: {} });
    put("stats", { log: union(cur.log || [], inc.log || [], (x) => x[0] + x[1]).sort((a, b) => a[0] - b[0]), meta: { ...(inc.meta || {}), ...(cur.meta || {}) } });
    done.push("analytics");
  }
  for (const k of ["settings", "taste"]) if (data[k] != null) { localStorage.setItem(k, data[k]); done.push(k); }
  return done;
}

/* ============================ import a playlist ============================ */
actions["pl-import"] = () => {
  openSheet(`<div class="sheet-title">Import songs</div><div class="sheet-pad">
    <input class="field" id="imp-name" placeholder="Playlist name" maxlength="60" autocomplete="off" aria-label="Playlist name">
    <textarea class="field" id="imp-text" rows="7" style="margin-top:10px;resize:none" placeholder="One song per line:&#10;Excuses - AP Dhillon&#10;Blinding Lights - The Weeknd&#10;&#10;or paste a CSV exported from another app" aria-label="Songs to import"></textarea>
    <button class="btn wide" style="margin-top:12px" data-act="imp-go">Find and add songs</button>
    <p class="fine" id="imp-msg">Each line is searched on YouTube Music and the best match is added. Up to 150 songs.</p></div>`);
};

/** One CSV row to cells, honouring "quoted, values". */
function cells(line) {
  const out = []; let cur = "", q = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (q) { if (c === '"') { if (line[i + 1] === '"') { cur += '"'; i++; } else q = false; } else cur += c; }
    else if (c === '"') q = true;
    else if (c === ",") { out.push(cur); cur = ""; }
    else cur += c;
  }
  return out.concat(cur).map((x) => x.trim());
}
/** Pasted text to search queries: plain lines, or the title and artist columns of a CSV. */
export function parseList(text) {
  const lines = text.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  if (!lines.length) return [];
  const head = cells(lines[0]).map((h) => h.toLowerCase());
  const ti = head.findIndex((h) => /^(track|song|title)( name)?$/.test(h) || h === "track name");
  if (ti >= 0 && head.length > 1) {
    const ai = head.findIndex((h) => /artist/.test(h));
    return lines.slice(1).map((l) => { const c = cells(l); return [c[ti], ai >= 0 ? (c[ai] || "").split(/[;|]/)[0] : ""].filter(Boolean).join(" "); }).filter(Boolean);
  }
  return lines.map((l) => l.replace(/^\s*\d+[.)]\s*/, "").replace(/\s+[-–—]\s+/, " ").replace(/\s+/g, " ")).filter(Boolean);
}

actions["imp-go"] = async (el) => {
  const queries = parseList($("#imp-text")?.value || "").slice(0, 150);
  const name = ($("#imp-name")?.value || "").trim() || "Imported playlist";
  const msg = $("#imp-msg");
  if (!queries.length) { toast("Paste some songs first"); return; }
  el.disabled = true;
  const found = new Array(queries.length).fill(null);
  let next = 0, done = 0;
  const worker = async () => {
    while (next < queries.length) {
      const i = next++;
      try { const r = await api(`/api/search?q=${encodeURIComponent(queries[i])}&filter=songs&limit=3`); found[i] = r[0] || null; } catch { found[i] = null; }
      done++;
      if (msg) msg.textContent = `Matching songs… ${done} of ${queries.length}`;
    }
  };
  await Promise.all([worker(), worker(), worker()]);
  const tracks = found.filter(Boolean), missed = queries.length - tracks.length;
  const seen = new Set(), unique = tracks.filter((t) => !seen.has(t.videoId) && seen.add(t.videoId));
  if (!unique.length) { if (msg) msg.textContent = "Couldn't match any of those. Check the names and your connection, then try again."; el.disabled = false; return; }
  const id = store.createPlaylist(name, unique);
  closeSheet(); refreshSide();
  toast(`Added ${unique.length} song${unique.length === 1 ? "" : "s"}${missed ? ` · ${missed} not found` : ""}`);
  navigate({ name: "local", id });
};
