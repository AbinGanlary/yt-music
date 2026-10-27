// Settings → Account: optional Google sign-in through Google's "TV device code" flow. You approve a short code on
// google.com/device; the app never sees your password. The tokens stay on this phone.
import { api, startSignIn, signOutYT } from "./api.js";
import { $, esc, toast } from "./ui.js";
import { openSheet, closeSheet } from "./sheets.js";
import { rerender, getCur } from "./nav.js";

export const actions = {};

const RISK = "This uses Google's sign-in for TV apps. It isn't an official way to use YouTube Music, so Google could limit the account. A spare account is the safer choice.";
const failText = (e) => String(e?.message || e || "unknown error").slice(0, 140);

actions["yt-signin"] = async () => {
  openSheet(`<div class="sheet-title">Sign in with Google</div><div class="sheet-pad"><p class="note" id="yt-msg" style="padding:0">Getting a sign-in code…</p></div>`);
  let s;
  try { s = await startSignIn(); }
  catch (e) { if ($("#yt-msg")) $("#yt-msg").textContent = "Couldn't start the sign-in: " + failText(e); return; }
  openSheet(`<div class="sheet-title">Sign in with Google</div><div class="sheet-pad">
    <ol class="yt-steps"><li>Open <b>google.com/device</b> on this phone or any device.</li><li>Choose your account and enter this code:</li></ol>
    <div class="yt-code" id="yt-code" aria-label="Sign-in code">${esc(s.code)}</div>
    <a class="btn wide" href="${esc(s.url)}" target="_blank" rel="noopener">Open google.com/device</a>
    <button class="btn wide ghost" style="margin-top:10px" data-act="yt-copy" data-code="${esc(s.code)}">Copy the code</button>
    <p class="fine" id="yt-msg">Waiting for you to approve it… The app notices on its own. The code works for about ${Math.round((s.expiresIn || 1800) / 60)} minutes.</p>
    <p class="fine">${RISK}</p></div>`);
  try { await s.done; }
  catch (e) { if ($("#yt-msg")) $("#yt-msg").textContent = "The sign-in wasn't completed: " + failText(e); return; }
  try { localStorage.setItem("ytacct", JSON.stringify(await api("/api/account"))); } catch {}
  closeSheet();
  toast("Signed in to YouTube");
  if (getCur() === "settings") rerender();
};

actions["yt-copy"] = async (el) => {
  try { await navigator.clipboard.writeText(el.dataset.code); toast("Code copied"); } catch { toast("Press and hold the code to copy it"); }
};

actions["yt-signout"] = () => {
  openSheet(`<div class="sheet-title">Sign out?</div><div class="sheet-pad"><p class="note" style="padding:0 0 12px">The app forgets your account on this phone and revokes its access. Your likes, playlists and analytics here stay.</p><button class="btn wide" style="background:#ff8a78;margin-bottom:10px" data-act="yt-signout-do">Sign out</button><button class="btn wide ghost" data-act="sheet-close">Cancel</button></div>`);
};
actions["yt-signout-do"] = async () => {
  await signOutYT();
  closeSheet();
  toast("Signed out");
  if (getCur() === "settings") rerender();
};
