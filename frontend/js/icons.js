// Stroke icons used by the design (24px grid, 1.8 stroke). `ic(name, size, opts)` returns an inline <svg>.
const P = {
  home: '<path d="M4 11l8-7 8 7"/><path d="M6 10v10h4v-6h4v6h4V10"/>',
  explore: '<circle cx="12" cy="12" r="8.5"/><path d="M15.5 8.5l-2 5-5 2 2-5z"/>',
  library: '<path d="M5 4v16"/><path d="M10 4v16"/><path d="M15 5.5l4 14.5"/>',
  download: '<path d="M12 4v11"/><path d="M7.5 10.5L12 15l4.5-4.5"/><path d="M5 20h14"/>',
  search: '<circle cx="11" cy="11" r="6.5"/><path d="M16 16l4.5 4.5"/>',
  cast: '<path d="M3 6V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2h-5"/><path d="M3 18a3 3 0 0 1 3 3"/><path d="M3 13a8 8 0 0 1 8 8"/>',
  thumb: '<path d="M7 11v9H4a1 1 0 0 1-1-1v-7a1 1 0 0 1 1-1h3z"/><path d="M7 11l4-7c1.5 0 2.5 1 2.2 2.6L12.8 9H19a2 2 0 0 1 2 2.3l-1.1 7A2 2 0 0 1 18 20H7"/>',
  shuffle: '<path d="M3 7h3.5c5 0 5 10 10 10H21"/><path d="M18 14l3 3-3 3"/><path d="M3 17h3.5c1.5 0 2.7-.6 3.6-1.6"/><path d="M14 8.6c.9-1 2.1-1.6 3.5-1.6H21"/><path d="M18 4l3 3-3 3"/>',
  repeat: '<path d="M17 3l3 3-3 3"/><path d="M4 11V9a3 3 0 0 1 3-3h13"/><path d="M7 21l-3-3 3-3"/><path d="M20 13v2a3 3 0 0 1-3 3H4"/>',
  repeat1: '<path d="M17 3l3 3-3 3"/><path d="M4 11V9a3 3 0 0 1 3-3h13"/><path d="M7 21l-3-3 3-3"/><path d="M20 13v2a3 3 0 0 1-3 3H4"/><path d="M11 10.5l1.5-1v6"/>',
  prev: '<path d="M7 6v12"/><path d="M19 6.5v11L9.5 12z" fill="currentColor"/>',
  next: '<path d="M17 6v12"/><path d="M5 6.5v11L14.5 12z" fill="currentColor"/>',
  play: '<path d="M8 5.5v13l11-6.5z" fill="currentColor" stroke="none"/>',
  pause: '<rect x="6.5" y="5" width="4" height="14" rx="1" fill="currentColor" stroke="none"/><rect x="13.5" y="5" width="4" height="14" rx="1" fill="currentColor" stroke="none"/>',
  dots: '<circle cx="12" cy="5.5" r="1.8" fill="currentColor" stroke="none"/><circle cx="12" cy="12" r="1.8" fill="currentColor" stroke="none"/><circle cx="12" cy="18.5" r="1.8" fill="currentColor" stroke="none"/>',
  chevDown: '<path d="M6 9l6 6 6-6"/>',
  chevRight: '<path d="M9 6l6 6-6 6"/>',
  back: '<path d="M15 6l-6 6 6 6"/>',
  close: '<path d="M6 6l12 12"/><path d="M18 6L6 18"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  radio: '<circle cx="12" cy="12" r="2"/><path d="M7.8 7.8a6 6 0 0 0 0 8.4"/><path d="M16.2 7.8a6 6 0 0 1 0 8.4"/><path d="M5 5a10 10 0 0 0 0 14"/><path d="M19 5a10 10 0 0 1 0 14"/>',
  playlistAdd: '<path d="M4 6h11"/><path d="M4 11h11"/><path d="M4 16h6"/><path d="M18 12v8"/><path d="M14 16h8"/>',
  queueAdd: '<path d="M4 7h11M4 12h11M4 17h7M18 14v6M15 17h6"/>',
  share: '<path d="M12 15V4"/><path d="M8 8l4-4 4 4"/><path d="M5 12v7a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-7"/>',
  album: '<circle cx="12" cy="12" r="8.5"/><circle cx="12" cy="12" r="2.5"/>',
  artist: '<circle cx="12" cy="8.5" r="3.5"/><path d="M5 20a7 7 0 0 1 14 0"/>',
  clock: '<circle cx="12" cy="12" r="8.5"/><path d="M12 8v4l3 2"/>',
  speed: '<path d="M4 16a8 8 0 1 1 16 0"/><path d="M12 16l4-5"/>',
  check: '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
  sort: '<path d="M7 4v16"/><path d="M3 16l4 4 4-4"/><path d="M17 20V4"/><path d="M13 8l4-4 4 4"/>',
  vol: '<path d="M4 9.5v5h3.5L12 18.5v-13L7.5 9.5z"/><path d="M15.5 9a4.5 4.5 0 0 1 0 6"/><path d="M18 6.5a8 8 0 0 1 0 11"/>',
  mute: '<path d="M4 9.5v5h3.5L12 18.5v-13L7.5 9.5z"/><path d="M16 9.5l5 5"/><path d="M21 9.5l-5 5"/>',
  panel: '<path d="M4 6h12"/><path d="M4 11h9"/><path d="M4 16h6"/><path d="M15 14v6l5-3z" fill="currentColor"/>',
  gear: '<circle cx="12" cy="12" r="3"/><path d="M19.4 14.5a1.6 1.6 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.6 1.6 0 0 0-1.8-.3 1.6 1.6 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.6 1.6 0 0 0-1-1.5 1.6 1.6 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.6 1.6 0 0 0 .3-1.8 1.6 1.6 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.6 1.6 0 0 0 1.5-1 1.6 1.6 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.6 1.6 0 0 0 1.8.3h0a1.6 1.6 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.6 1.6 0 0 0 1 1.5 1.6 1.6 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.6 1.6 0 0 0-.3 1.8v0a1.6 1.6 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.6 1.6 0 0 0-1.5 1z"/>',
  file: '<path d="M7 3.5h7l4 4V20a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1V4.5a1 1 0 0 1 1-1zM14 3.5V8h4M12 17v-5m0 0l-2 2m2-2l2 2"/>',
  bell: '<path d="M6 17V11a6 6 0 0 1 12 0v6l1.5 2h-15zM10 21a2 2 0 0 0 4 0"/>',
  trash: '<path d="M5 7h14M10 7V4.5h4V7M7 7l.8 12.5h8.4L17 7"/>',
  edit: '<path d="M4 20h4L19 9l-4-4L4 16z"/><path d="M13.5 6.5l4 4"/>',
  chart: '<path d="M5 20v-8"/><path d="M12 20V4"/><path d="M19 20v-5"/>',
};

export function ic(name, size = 24, o = {}) {
  return `<svg class="ic${o.cls ? " " + o.cls : ""}" width="${size}" height="${size}" viewBox="0 0 24 24" fill="${o.fill ? "currentColor" : "none"}" stroke="currentColor" stroke-width="${o.sw || (name === "prev" || name === "next" || name === "close" || name === "chevDown" ? 2 : 1.8)}" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${P[name] || ""}</svg>`;
}

/** The brand mark from the design: an accent-coloured disc with a tall bar, a short bar and a dot. */
export const logo = (size = 28) => `<svg width="${size}" height="${size}" viewBox="0 0 220 220" aria-hidden="true"><circle cx="110" cy="110" r="110" fill="var(--accent)"/><rect x="65" y="60" width="24" height="100" rx="12" fill="#1a0a05"/><rect x="102" y="80" width="24" height="62" rx="12" fill="#1a0a05"/><circle cx="151" cy="111" r="12" fill="#1a0a05"/></svg>`;
