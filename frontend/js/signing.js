// Signing for updates (stage 1): import your certificate (.p12) and provisioning profile and check they fit this phone.
// The files stay in the app's private storage (see ios-app/native/Signer.swift); the password goes to the Keychain.
import { esc, toast } from "./ui.js";
import { openSheet } from "./sheets.js";

export const actions = {};
let pendingP12 = null;            // base64 of the chosen .p12 while the password is typed

const plugin = () => { const c = window.Capacitor; try { return c?.Plugins?.Signer ?? c?.registerPlugin?.("Signer") ?? null; } catch { return null; } };
const base64 = (file) => new Promise((res, rej) => { const r = new FileReader(); r.onload = () => res(String(r.result).split(",")[1] || ""); r.onerror = () => rej(r.error); r.readAsDataURL(file); });
const day = (ms) => new Date(ms).toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });

const CHECKS = [
  ["certValid", "Certificate has not expired"],
  ["profileValid", "Profile has not expired"],
  ["certInProfile", "Certificate is listed in the profile"],
  ["bundleMatch", "Profile covers this app's bundle ID"],
  ["sameTeam", "Same team as the installed app"],
  ["deviceIncluded", "This iPhone is included"],
];
const line = (ok, text) => `<li><span class="${ok === true ? "sg-ok" : ok === false ? "sg-bad" : "sg-na"}">${ok === true ? "✓" : ok === false ? "✕" : "–"}</span><span>${esc(text)}</span></li>`;

function view(st) {
  const c = st.cert, p = st.profile, k = st.checks || {};
  const ready = CHECKS.every(([id]) => k[id] !== false) && c && p && k.certValid && k.profileValid && k.certInProfile && k.bundleMatch;
  const certBlock = pendingP12
    ? `<div class="sheet-pad" style="padding:0 0 14px"><p class="fine">Type the password for that certificate file.</p>
        <input class="field" id="sg-pw" type="password" autocomplete="off" autocapitalize="off" spellcheck="false" placeholder="Certificate password" aria-label="Certificate password">
        <button class="btn wide" style="margin-top:10px" data-act="sign-p12-go">Import certificate</button></div>`
    : `<p class="fine" style="margin:0 0 8px">${c ? `${esc(c.name)}, valid to ${esc(day(c.expires))}` : "No certificate imported yet."}</p>
       <label class="btn ghost wide" for="sg-p12" role="button">${c ? "Replace" : "Choose"} certificate (.p12)</label><input id="sg-p12" type="file" hidden>`;
  const profBlock = `<p class="fine" style="margin:0 0 8px">${p ? `${esc(p.name)}, ${esc(p.appId)}${p.expires ? `, valid to ${esc(day(p.expires))}` : ""}` : "No profile imported yet."}</p>
       <label class="btn ghost wide" for="sg-prov" role="button">${p ? "Replace" : "Choose"} profile (.mobileprovision)</label><input id="sg-prov" type="file" hidden>`;
  const checks = c && p ? `<ul class="sg-list">${CHECKS.map(([id, t]) => line(k[id], t)).join("")}${line(k.certIsInstalledOne === undefined ? undefined : k.certIsInstalledOne, "Same certificate this app was installed with")}</ul>
      <p class="fine">${ready ? "Everything fits. Signing updates here comes next." : "Something doesn't fit, so signing here would fail. Fix the ✕ lines (usually a different profile or certificate)."}</p>` : "";
  return `<div class="sheet-title">Signing for updates</div><div class="sheet-pad">
    <p class="fine">Keep your certificate and provisioning profile on this phone, in this app's private storage, so updates can be signed here. They are not backed up, not uploaded and not in the repository.</p>
    <h3 class="sg-h">Certificate</h3>${certBlock}
    <h3 class="sg-h">Provisioning profile</h3>${profBlock}
    ${checks}
    ${c || p ? `<button class="btn ghost wide" style="margin-top:12px" data-act="sign-remove">Remove both from this phone</button>` : ""}</div>`;
}

async function show() {
  const s = plugin();
  if (!s) { openSheet(`<div class="sheet-title">Signing for updates</div><div class="sheet-pad"><p class="fine">This only works in the iPhone app.</p></div>`); return; }
  try { openSheet(view(await s.status())); } catch (e) { toast("Couldn't read the saved signing files"); }
}

actions["sign-open"] = () => { pendingP12 = null; show(); };
actions["sign-p12-go"] = async () => {
  const pw = document.querySelector("#sg-pw")?.value || "";
  if (!pendingP12 || !pw) { toast("Type the certificate password"); return; }
  try { await plugin().importCertificate({ data: pendingP12, password: pw }); pendingP12 = null; toast("Certificate imported"); }
  catch (e) { toast(e?.message || "Couldn't import that certificate"); }
  show();
};
actions["sign-remove"] = async () => { try { await plugin().remove(); } catch {} pendingP12 = null; toast("Removed from this phone"); show(); };

document.addEventListener("change", async (e) => {
  const f = e.target.files?.[0];
  if (!f || (e.target.id !== "sg-p12" && e.target.id !== "sg-prov")) return;
  try {
    const data = await base64(f);
    if (e.target.id === "sg-p12") { pendingP12 = data; show(); }
    else { await plugin().importProfile({ data }); toast("Profile imported"); show(); }
  } catch (err) { toast(err?.message || "Couldn't read that file"); }
  e.target.value = "";
});
