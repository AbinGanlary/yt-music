// User preferences and "taste". Kept in localStorage (no store.js import: api.js depends on this file).
const read = (k, d) => { try { return JSON.parse(localStorage.getItem(k)) ?? d; } catch { return d; } };
const write = (k, v) => { try { localStorage.setItem(k, JSON.stringify(v)); } catch {} };

export const QUALITIES = {
  high: { label: "High", detail: "≈128 kbps AAC · about 4 MB a song" },
  low: { label: "Data saver", detail: "≈48 kbps · about 1.6 MB a song" },
};
export const LANGUAGES = [
  "Hindi", "English", "Punjabi", "Tamil", "Telugu", "Malayalam", "Kannada", "Bengali", "Marathi",
  "Gujarati", "Bhojpuri", "Haryanvi", "Urdu", "Korean", "Japanese", "Spanish", "Portuguese", "French", "Arabic",
];

export const ACCENTS = [["#ff6a3d", "Coral"], ["#7c8cff", "Periwinkle"], ["#2dd4a7", "Mint"], ["#f5c542", "Amber"]];
const defaults = {
  quality: "high", dlQuality: "high", playback: "auto", sponsorBlock: false, dynamic: true, autoplay: true, smartDl: false, saveHistory: true,
  uiNav: "glass", uiNp: "blur", // "classic" | "glass" (tab bar + mini player), "classic" | "blur" (full-screen player)
  accent: "#ff6a3d",            // a colour, or "art" to follow the album artwork
  bottomNudge: 0,               // px to extend the app below the reported window height
  global: true,                 // Home, Quick picks, New releases, Trending and Charts show worldwide music; off = follow `location`
  location: "auto", country: "IN",
};
let state = { ...defaults, ...read("settings", {}) };
let taste = { languages: [], artists: [], ...read("taste", {}) };

export const bus = new EventTarget();
export const get = () => state;
export function set(patch) {
  state = { ...state, ...patch };
  write("settings", state);
  bus.dispatchEvent(new CustomEvent("change", { detail: patch }));
}
export const getTaste = () => taste;
export function setTaste(patch) {
  taste = { ...taste, ...patch };
  write("taste", taste);
  bus.dispatchEvent(new CustomEvent("taste"));
}
export const hasTaste = () => taste.languages.length > 0 || taste.artists.length > 0;

const TZ = {
  "Asia/Kolkata": "IN", "Asia/Calcutta": "IN", "Asia/Dubai": "AE", "Asia/Karachi": "PK", "Asia/Dhaka": "BD", "Asia/Colombo": "LK",
  "Asia/Kathmandu": "NP", "Asia/Singapore": "SG", "Asia/Kuala_Lumpur": "MY", "Asia/Jakarta": "ID", "Asia/Manila": "PH", "Asia/Bangkok": "TH",
  "Asia/Ho_Chi_Minh": "VN", "Asia/Tokyo": "JP", "Asia/Seoul": "KR", "Asia/Hong_Kong": "HK", "Asia/Taipei": "TW", "Asia/Riyadh": "SA", "Asia/Qatar": "QA",
  "Europe/London": "GB", "Europe/Dublin": "IE", "Europe/Paris": "FR", "Europe/Berlin": "DE", "Europe/Madrid": "ES", "Europe/Rome": "IT",
  "Europe/Amsterdam": "NL", "Europe/Stockholm": "SE", "Europe/Istanbul": "TR",
  "America/New_York": "US", "America/Chicago": "US", "America/Denver": "US", "America/Los_Angeles": "US", "America/Phoenix": "US",
  "America/Toronto": "CA", "America/Vancouver": "CA", "America/Mexico_City": "MX", "America/Sao_Paulo": "BR", "America/Argentina/Buenos_Aires": "AR",
  "Australia/Sydney": "AU", "Australia/Melbourne": "AU", "Pacific/Auckland": "NZ",
  "Africa/Lagos": "NG", "Africa/Johannesburg": "ZA", "Africa/Cairo": "EG", "Africa/Nairobi": "KE",
};
/**
 * Best guess of the user's country with no GPS or permission prompt.
 * Time zone first (language settings often say en-US on phones elsewhere), then the language region.
 */
export function autoRegion() {
  try {
    const z = TZ[Intl.DateTimeFormat().resolvedOptions().timeZone];
    if (z) return z;
  } catch {}
  for (const l of navigator.languages || [navigator.language || ""]) {
    const m = /[-_]([A-Za-z]{2})$/.exec(l);
    if (m) return m[1].toUpperCase();
  }
  return "";
}
/** The country chosen in Location (or the device's), whether or not Global content is on. */
export const localLoc = () => (state.location === "auto" ? autoRegion() : state.country) || "";
/** The country that catalogue calls follow: none while Global content is on. */
export const loc = () => (state.global ? "" : localLoc());
export function regionName(code) {
  try { return new Intl.DisplayNames(["en"], { type: "region" }).of(code) || code; } catch { return code; }
}
