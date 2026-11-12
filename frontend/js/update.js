// Update check. Asks GitHub for the latest release and says when a newer build exists.
// An iPhone app can't replace itself, so "Download" opens the new .ipa; you import or install it over this app with your own tool
// (for example LiveContainer), and your data is kept.
import { APP_VERSION, APP_NAME, toast, esc } from "./ui.js";
import * as store from "./store.js";
import { openSheet } from "./sheets.js";
import { rerender, getCur } from "./nav.js";

const REPO = "AbinGanlary/yt-music", SAFE = `https://github.com/${REPO}/`, EVERY = 12 * 3600e3;
export const actions = {};

const parts = (v) => v.split(".").map((n) => Number(n) || 0);
const newer = (a, b) => { const x = parts(a), y = parts(b); for (let i = 0; i < 3; i++) if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) > (y[i] || 0); return false; };

/** The newer release found by the last check, or null. */
export const pending = () => { const u = store.kv.get("update", null); return u && newer(u.version, APP_VERSION) ? u : null; };

/** Looks for a newer release (at most every 12 hours unless forced). Resolves to the release, or null when up to date. */
export async function check({ force = false } = {}) {
  if (!force && Date.now() - store.kv.get("updateCheckedAt", 0) < EVERY) return pending();
  const r = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, { headers: { Accept: "application/vnd.github+json" }, cache: "no-store" });
  if (!r.ok) throw new Error(`GitHub answered ${r.status}`);
  const j = await r.json();
  store.kv.set("updateCheckedAt", Date.now());
  const version = String(j.tag_name || "").replace(/^v/i, "");
  if (!/^\d+\.\d+\.\d+$/.test(version) || !newer(version, APP_VERSION)) { store.kv.set("update", null); return null; }
  const ipa = (j.assets || []).find((a) => /\.ipa$/i.test(a.name))?.browser_download_url;
  const u = { version, notes: String(j.body || "").slice(0, 700), ipa: ipa?.startsWith(SAFE) ? ipa : null, page: String(j.html_url || "").startsWith(SAFE) ? j.html_url : `${SAFE}releases/latest` };
  store.kv.set("update", u);
  return u;
}

/** Check now and tell the person the result (Settings → About). */
export async function checkNow() {
  toast("Checking for updates…", 60000);
  try {
    const u = await check({ force: true });
    if (u) { toast(`${APP_NAME} v${u.version} is available`); openUpdate(); } else toast(`You're up to date (v${APP_VERSION})`);
  } catch { toast("Couldn't check for updates. Are you online?"); }
  if (getCur() === "home" || getCur() === "settings") rerender();
}

export function openUpdate() {
  const u = pending(); if (!u) return;
  const notes = u.notes.split(/\r?\n/).map((l) => l.trim()).filter(Boolean).slice(0, 8).map((l) => `<li>${esc(l.replace(/^[-*]\s*/, ""))}</li>`).join("");
  openSheet(`<div class="sheet-title">${esc(APP_NAME)} v${esc(u.version)} is ready</div><div class="sheet-pad">
    <p class="fine">You have v${esc(APP_VERSION)}.</p>
    <ul class="yt-steps">${notes}</ul>
    ${u.ipa ? `<a class="btn wide" href="${esc(u.ipa)}" target="_blank" rel="noopener">Download update (.ipa)</a>` : ""}
    <a class="btn ghost wide" style="margin-top:10px" href="${esc(u.page)}" target="_blank" rel="noopener">See what's new on GitHub</a>
    <p class="fine" style="margin-top:12px">After it downloads, import it into LiveContainer (or install it with your signing tool) over this app. Your songs, likes and settings are kept. Use Backup first if you remove the old copy.</p></div>`);
}

actions["update-open"] = () => openUpdate();
actions["hide-update"] = () => { const u = pending(); if (u) store.kv.set("hideUpdate", u.version); rerender(); };
