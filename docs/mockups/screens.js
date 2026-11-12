// Draws the mockup screens. Open index.html#home (or #now, #lyrics, #explore, #mix, #library, #analytics, #settings).
const I = (d, extra = "") => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" ${extra}>${d}</svg>`;
const F = (d) => `<svg viewBox="0 0 24 24" fill="currentColor">${d}</svg>`;
const ICON = {
  home: I('<path d="M3 11l9-8 9 8"/><path d="M5 10v10h5v-6h4v6h5V10"/>'),
  mix: I('<circle cx="12" cy="12" r="2"/><path d="M7.5 7.5a6.4 6.4 0 000 9M16.5 7.5a6.4 6.4 0 010 9M4.6 4.6a10.5 10.5 0 000 14.8M19.4 4.6a10.5 10.5 0 010 14.8"/>'),
  explore: I('<circle cx="12" cy="12" r="9"/><path d="M15.5 8.5l-2 5-5 2 2-5z"/>'),
  library: I('<path d="M5 4v16M10 4v16M15 5l4 15"/>'),
  chart: F('<rect x="3" y="12" width="5" height="9" rx="1.2"/><rect x="9.5" y="3" width="5" height="18" rx="1.2"/><rect x="16" y="8" width="5" height="13" rx="1.2"/>'),
  gear: I('<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 00.3 1.8l.1.1a2 2 0 11-2.8 2.8l-.1-.1a1.7 1.7 0 00-1.8-.3 1.7 1.7 0 00-1 1.5V21a2 2 0 11-4 0v-.1a1.7 1.7 0 00-1.1-1.5 1.7 1.7 0 00-1.8.3l-.1.1a2 2 0 11-2.8-2.8l.1-.1a1.7 1.7 0 00.3-1.8 1.7 1.7 0 00-1.5-1H3a2 2 0 110-4h.1a1.7 1.7 0 001.5-1.1 1.7 1.7 0 00-.3-1.8l-.1-.1a2 2 0 112.8-2.8l.1.1a1.7 1.7 0 001.8.3H9a1.7 1.7 0 001-1.5V3a2 2 0 114 0v.1a1.7 1.7 0 001 1.5 1.7 1.7 0 001.8-.3l.1-.1a2 2 0 112.8 2.8l-.1.1a1.7 1.7 0 00-.3 1.8V9a1.7 1.7 0 001.5 1H21a2 2 0 110 4h-.1a1.7 1.7 0 00-1.5 1z"/>'),
  list: I('<rect x="3" y="4" width="18" height="16" rx="3"/><path d="M7 9h10M7 13h10M7 17h6"/>'),
  search: I('<circle cx="11" cy="11" r="7"/><path d="M20 20l-3.5-3.5"/>'),
  heart: I('<path d="M12 20s-7-4.4-9-9.3C1.8 7 4 4 7 4c2 0 3.5 1.1 5 3 1.5-1.9 3-3 5-3 3 0 5.2 3 4 6.7-2 4.9-9 9.3-9 9.3z"/>'),
  heartF: F('<path d="M12 21s-8-5-10-10.2C.8 6.7 3.3 3.5 6.8 3.5c2 0 3.7 1 5.2 3 1.5-2 3.2-3 5.2-3 3.5 0 6 3.2 4.8 7.3C20 16 12 21 12 21z"/>'),
  down: I('<path d="M12 4v11"/><path d="M7.5 10.5L12 15l4.5-4.5"/><path d="M5 20h14"/>'),
  downC: I('<circle cx="12" cy="12" r="9"/><path d="M12 7v9M8.5 12.5L12 16l3.5-3.5"/>'),
  clock: I('<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>'),
  note: I('<path d="M9 18V5l11-2v13"/><circle cx="6.5" cy="18" r="2.5"/><circle cx="17.5" cy="16" r="2.5"/>'),
  play: F('<path d="M7 4.5v15l13-7.5z"/>'),
  pause: F('<rect x="6" y="4.5" width="4.4" height="15" rx="1.2"/><rect x="13.6" y="4.5" width="4.4" height="15" rx="1.2"/>'),
  fwd: F('<path d="M3 5.5v13l9-6.5zM12 5.5v13l9-6.5z"/>'),
  back: F('<path d="M21 5.5v13l-9-6.5zM12 5.5v13l-9-6.5z"/>'),
  playC: F('<circle cx="12" cy="12" r="11"/><path d="M9.5 7.5v9l7.5-4.5z" fill="#0c0c0f"/>'),
  pauseC: F('<circle cx="12" cy="12" r="11"/><rect x="8.3" y="7.5" width="2.7" height="9" rx=".8" fill="#0c0c0f"/><rect x="13" y="7.5" width="2.7" height="9" rx=".8" fill="#0c0c0f"/>'),
  shuffle: I('<path d="M3 7h3c4 0 5 10 9 10h3M3 17h3c1.5 0 2.5-1.2 3.4-2.7M13 8.2C13.8 7.5 14.6 7 15 7h3"/><path d="M16 4l3 3-3 3M16 14l3 3-3 3"/>'),
  repeat: I('<path d="M17 2l4 4-4 4"/><path d="M3 11V9a3 3 0 013-3h15"/><path d="M7 22l-4-4 4-4"/><path d="M21 13v2a3 3 0 01-3 3H3"/>'),
  thumb: I('<path d="M17 14V3M17 14l-3 7a2.5 2.5 0 01-2.4-2v-3.5H6.3a2 2 0 01-2-2.4l1-6A2 2 0 017.3 4H17"/>'),
  speed: I('<circle cx="12" cy="13" r="8.5"/><path d="M12 13l4-4M7 17h.01M5.5 12h.01M12 5.5h.01M18.5 12h.01"/>'),
  moon: I('<path d="M20 14.5A8 8 0 019.5 4 8 8 0 1020 14.5z"/>'),
  radio: I('<circle cx="12" cy="12" r="2"/><path d="M7.8 7.8a6 6 0 000 8.4M16.2 7.8a6 6 0 010 8.4"/>'),
  share: I('<path d="M12 15V3M8 7l4-4 4 4"/><path d="M5 12v7a2 2 0 002 2h10a2 2 0 002-2v-7"/>'),
  airplay: I('<path d="M5 17H4a2 2 0 01-2-2V5a2 2 0 012-2h16a2 2 0 012 2v10a2 2 0 01-2 2h-1"/><path d="M12 15l5 6H7z"/>'),
  chev: I('<path d="M9 5l7 7-7 7"/>', 'class="chev"'),
  plus: I('<path d="M12 5v14M5 12h14"/>'),
  dots: I('<circle cx="12" cy="12" r="9"/><path d="M8 12h.01M12 12h.01M16 12h.01" stroke-width="3"/>'),
  wave: F('<rect x="3" y="9" width="3" height="6" rx="1.2"/><rect x="8" y="4" width="3" height="16" rx="1.2"/><rect x="13" y="7" width="3" height="10" rx="1.2"/><rect x="18" y="10" width="3" height="4" rx="1.2"/>'),
};

// generated artwork: each cover is a gradient with a simple shape on top
const ART = [
  ["#ff7a59", "#7c3aed", "sun"], ["#2dd4a7", "#0f3d5e", "rings"], ["#f5c542", "#e5484d", "stripes"], ["#7c8cff", "#1b1b4d", "moon"],
  ["#ff5c8a", "#ffb199", "waves"], ["#4cc3ff", "#143a6b", "grid"], ["#a78bfa", "#2a0f5a", "sun"], ["#a3e635", "#14532d", "rings"],
  ["#ff9f43", "#3b1d6a", "stripes"], ["#34d399", "#065f46", "moon"], ["#fb7185", "#4c0519", "waves"], ["#60a5fa", "#1e1b4b", "grid"],
];
function art(i) {
  const [a, b, kind] = ART[i % ART.length];
  const shape = {
    sun: "radial-gradient(circle at 68% 30%, rgba(255,255,255,.55) 0 15%, transparent 16%)",
    rings: "radial-gradient(circle at 50% 55%, transparent 0 22%, rgba(255,255,255,.35) 23% 25%, transparent 26% 40%, rgba(255,255,255,.22) 41% 43%, transparent 44%)",
    stripes: "repeating-linear-gradient(135deg, rgba(255,255,255,.16) 0 10px, transparent 10px 22px)",
    moon: "radial-gradient(circle at 36% 38%, rgba(255,255,255,.85) 0 13%, transparent 14%), radial-gradient(circle at 44% 34%, " + b + " 0 12%, transparent 13%)",
    waves: "repeating-radial-gradient(circle at 20% 110%, rgba(255,255,255,.22) 0 6px, transparent 6px 16px)",
    grid: "linear-gradient(rgba(255,255,255,.14) 1px, transparent 1px) 0 0/18% 18%, linear-gradient(90deg, rgba(255,255,255,.14) 1px, transparent 1px) 0 0/18% 18%",
  }[kind];
  return `${shape}, linear-gradient(150deg, ${a}, ${b})`;
}
const cover = (i, w, h, r) => `<div class="cover" style="width:${w}px;height:${h || w}px;${r != null ? `border-radius:${r}px;` : ""}background:${art(i)}"></div>`;

const SONGS = [
  ["Midnight Drive", "Neon Harbor", "3:34", 0], ["Paper Planes", "Lila Moreno", "3:07", 1], ["Slow Burn", "The Quiet Hours", "4:03", 2],
  ["Golden Hour", "Sunday Static", "3:21", 3], ["Wildflower", "Mira & the Tides", "2:56", 4], ["City Lights", "Arjun Rao", "3:52", 5],
  ["Echoes", "Neon Harbor", "4:18", 6], ["Afterglow", "Lila Moreno", "3:15", 7],
];
const row = (s, playing) => `<div class="row">${cover(s[3], 52, 52, 8)}<div class="meta"><div class="t">${playing ? `<span class="wave">${ICON.wave}</span>` : ""}${s[0]}</div><div class="a">${s[1]}</div></div><div class="d">${s[2]}</div></div>`;
const card = (s) => `<div class="card">${cover(s[3], 124, 124, 12)}<div class="t">${s[0]}</div><div class="a">${s[1]}</div></div>`;

const TAB = [["home", "Home"], ["mix", "Mix"], ["explore", "Explore"], ["library", "Library"], ["chart", "Analytics"]];
const tabs = (on) => `<div class="tabs">${TAB.map(([k, l]) => `<div class="${k === on ? "on" : ""}">${ICON[k]}<span>${l}</span></div>`).join("")}</div>`;
const mini = (s = SONGS[0]) => `<div class="mini"><div class="top">${cover(s[3], 46, 46, 15)}<div class="meta"><div class="t">${s[0]}</div><div class="a">${s[1]}</div></div>${ICON.pause}${ICON.fwd}</div><div class="bar"><i></i></div></div>`;
const status = `<div class="island"></div><div class="status"><span>9:41</span><span class="icons"><svg width="18" height="12" viewBox="0 0 18 12" fill="#fff"><rect x="0" y="8" width="3" height="4" rx="1"/><rect x="5" y="5" width="3" height="7" rx="1"/><rect x="10" y="2" width="3" height="10" rx="1"/><rect x="15" y="0" width="3" height="12" rx="1" opacity=".4"/></svg><svg width="17" height="12" viewBox="0 0 17 12" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round"><path d="M1.5 4.2a10 10 0 0114 0M4 7a6.4 6.4 0 019 0"/><circle cx="8.5" cy="10" r="1.3" fill="#fff" stroke="none"/></svg><span class="batt">92</span></span></div>`;
const nav = (...icons) => `<div class="nav"><div class="pill">${icons.join('<span style="width:10px"></span>')}</div></div>`;
const frame = (inner) => `<div class="device"><div class="screen">${status}${inner}</div></div>`;

const SCREENS = {
  home: () => frame(`
    ${nav(ICON.list, ICON.gear)}
    <div class="title">YT Music</div>
    <div class="search">${ICON.search}Search songs</div>
    <div class="chips"><span class="chip on">All</span><span class="chip">Relax</span><span class="chip">Sleep</span><span class="chip">Energize</span><span class="chip">Sad</span><span class="chip">Romance</span></div>
    <div class="sec"><h2>Listen again</h2></div>
    <div class="shelf">${[SONGS[1], SONGS[3], SONGS[4]].map(card).join("")}</div>
    <div class="sec"><div class="cap">Start radio from a song</div><h2>Quick picks</h2></div>
    <div style="height:6px"></div>
    ${row(SONGS[0], true)}${row(SONGS[2])}${row(SONGS[5])}
    ${mini()}${tabs("home")}`),

  now: () => frame(`<div class="np"><div class="glow" style="background:${art(0)}"></div><div class="shade"></div><div class="in">
    <div class="handle"></div>
    <div class="seg"><div class="on">Song</div><div>Lyrics</div><div>Queue</div></div>
    <div class="stage">${cover(0, 336, 336, 20).replace('class="cover"', 'class="cover big"')}</div>
    <div class="tt"><div class="m"><div class="t">Midnight Drive</div><div class="a">Neon Harbor</div></div><span style="color:var(--muted)">${ICON.thumb}</span><span style="color:var(--accent)">${ICON.heartF}</span></div>
    <div class="scrub"><div class="line"><i></i><b></b></div><div class="times"><span>1:18</span><span>-2:16</span></div></div>
    <div class="ctrls"><span class="sm">${ICON.shuffle}</span>${ICON.back}<span class="play">${ICON.pauseC}</span>${ICON.fwd}<span class="sm" style="color:var(--accent)">${ICON.repeat}</span></div>
    <div class="utils"><span>${ICON.speed}1×</span><span>${ICON.moon}Sleep</span><span>${ICON.radio}Radio</span><span>${ICON.share}Save</span><span>${ICON.airplay}</span></div>
  </div></div>`),

  lyrics: () => frame(`<div class="np"><div class="glow" style="background:${art(3)}"></div><div class="shade"></div><div class="in">
    <div class="handle"></div>
    <div class="seg"><div>Song</div><div class="on">Lyrics</div><div>Queue</div></div>
    <div class="stage" style="align-items:flex-start;overflow:hidden"><div class="lyrics" style="width:100%">
      <p>Streetlights bleeding into the rain</p><p>You said we would never be the same</p>
      <p class="on">Hold the line, I'm coming home tonight</p>
      <p>Every window has a different light</p><p>Turn the radio up, let it ride</p><p>Nowhere left to run, nowhere left to hide</p></div></div>
    <div class="tt"><div class="m"><div class="t">Golden Hour</div><div class="a">Sunday Static</div></div><span style="color:var(--muted)">${ICON.thumb}</span>${ICON.heart}</div>
    <div class="scrub"><div class="line"><i style="width:52%"></i><b style="left:52%"></b></div><div class="times"><span>1:42</span><span>-1:39</span></div></div>
    <div class="ctrls"><span class="sm">${ICON.shuffle}</span>${ICON.back}<span class="play">${ICON.pauseC}</span>${ICON.fwd}<span class="sm">${ICON.repeat}</span></div>
    <div class="utils"><span>${ICON.speed}1×</span><span>${ICON.moon}Sleep</span><span>${ICON.radio}Radio</span><span>${ICON.share}Save</span><span>${ICON.airplay}</span></div>
  </div></div>`),

  explore: () => frame(`
    ${nav(ICON.gear)}
    <div class="title">Explore</div>
    <div class="sec"><h2>New releases</h2></div>
    <div class="shelf" style="padding-top:10px">${[["A Beautiful Journey", "RERN", 5], ["The Girl Of Your Dreams", "Ashe", 4], ["Jailer 2", "Anirudh", 2]].map(([t, a, i]) => `<div class="card" style="width:128px">${cover(i, 128, 128, 12)}<div class="t">${t}</div><div class="a">${a}</div></div>`).join("")}</div>
    <div class="sec"><h2>Charts</h2></div>
    <div class="shelf" style="padding-top:10px">${[["Daily Top Videos", 8], ["Weekly Top 100", 10]].map(([t, i]) => `<div class="card" style="width:128px">${cover(i, 128, 128, 12)}<div class="t">${t}</div><div class="a">Chart</div></div>`).join("")}</div>
    <div class="sec"><h2>Moods &amp; genres</h2></div>
    <div class="tiles">${[["Chill", 0], ["Focus", 5], ["Workout", 2], ["Party", 4]].map(([t, i]) => `<div class="tile" style="background:linear-gradient(135deg,${ART[i][0]},${ART[i][1]})">${t}</div>`).join("")}</div>
    ${tabs("explore")}`),

  mix: () => frame(`
    ${nav(ICON.plus, ICON.gear)}
    <div class="title">Mix</div>
    <div class="chips"><span class="chip on">All</span><span class="chip">Lo-fi</span><span class="chip">Indie</span><span class="chip">Jazz</span></div>
    <div style="padding:0 20px 8px"><span class="btn">${ICON.play.replace('<svg', '<svg width="16" height="16"')}Play mix</span></div>
    <div class="sec" style="display:flex;justify-content:space-between;align-items:baseline"><h2>Lo-fi</h2><span class="cap">Remove</span></div>
    <div style="height:4px"></div>${row(SONGS[1])}${row(SONGS[4])}${row(SONGS[7])}
    <div class="sec" style="display:flex;justify-content:space-between;align-items:baseline;margin-top:8px"><h2>Indie</h2><span class="cap">Remove</span></div>
    <div style="height:4px"></div>${row(SONGS[3])}${row(SONGS[6])}
    ${mini(SONGS[4])}${tabs("mix")}`),

  library: () => frame(`
    ${nav(ICON.gear, ICON.dots)}
    <div class="title">Library</div>
    <div class="group">
      <div class="entry"><div class="ic">${ICON.heartF}</div><div class="m"><div class="t">Liked songs</div><div class="a">42 songs</div></div>${ICON.chev}</div>
      <div class="entry"><div class="ic">${ICON.downC}</div><div class="m"><div class="t">Downloads</div><div class="a">18 songs</div></div>${ICON.chev}</div>
      <div class="entry"><div class="ic">${ICON.clock}</div><div class="m"><div class="t">History</div><div class="a">60 songs</div></div>${ICON.chev}</div>
    </div>
    <div class="sec" style="display:flex;justify-content:space-between;align-items:center;margin-top:18px"><h2>Playlists</h2><span style="color:var(--accent);width:26px">${ICON.plus}</span></div>
    <div class="group" style="margin-top:6px">
      ${[["Road trip", "24 songs"], ["Focus", "31 songs"], ["Late night", "17 songs"]].map(([t, s]) => `<div class="entry"><div class="ic">${ICON.note}</div><div class="m"><div class="t">${t}</div><div class="a">${s}</div></div>${ICON.chev}</div>`).join("")}
    </div>
    ${mini(SONGS[2])}${tabs("library")}`),

  analytics: () => frame(`
    ${nav(ICON.gear)}
    <div class="title">Analytics</div>
    <div class="wrapped"><div class="k">YOUR LISTENING, SO FAR</div><div class="big">6 h 42 min</div>
      <div class="two"><div>Top artist<b>Neon Harbor</b></div><div>Top song<b>Midnight Drive</b></div></div>
      <div class="share">${ICON.share.replace('<svg', '<svg width="15" height="15"')}Share</div></div>
    <div class="tiles3"><div><b>6 h 42 min</b><span>Time</span></div><div><b>118</b><span>Songs played</span></div><div><b>9</b><span>Day streak</span></div></div>
    <div class="panel"><h3>Last 7 days</h3><div class="bars">${[["Fri", 55], ["Sat", 80], ["Sun", 100], ["Mon", 30], ["Tue", 62], ["Wed", 44], ["Thu", 72]].map(([d, h]) => `<div class="c"><i style="height:${h}%"></i><span>${d}</span></div>`).join("")}</div></div>
    <div class="panel"><h3>By hour of the day</h3><div class="hours">${[2, 1, 0, 0, 0, 1, 3, 6, 5, 4, 3, 4, 5, 4, 5, 6, 7, 9, 10, 12, 14, 11, 8, 4].map((v, h) => `<i class="${h === 20 ? "p" : ""}" style="height:${Math.max(4, v * 5)}px"></i>`).join("")}</div><div class="axis"><span>12 AM</span><span>6 AM</span><span>12 PM</span><span>6 PM</span></div></div>
    ${tabs("chart")}`),

  settings: () => frame(`
    <div class="sheet-top">Settings<div class="done">Done</div></div>
    <div class="list">
      <div class="h">Playback</div>
      <div class="g"><div class="r">Keep playing similar songs<div class="sw on"></div></div><div class="r">Dynamic queue<div class="sw on"></div></div><div class="r">Skip non-music parts<div class="sw"></div></div></div>
      <div class="h">Sound</div>
      <div class="g"><div class="r">Audio quality<span class="v">High ⌃</span></div><div class="r">How songs start<span class="v">Auto ⌃</span></div></div>
      <div class="h">Downloads</div>
      <div class="g"><div class="r">Download quality<span class="v">High ⌃</span></div><div class="r">Smart downloads<div class="sw on"></div></div><div class="r">Saved songs<span style="color:var(--muted)">18</span></div></div>
      <div class="h">Appearance</div>
      <div class="g"><div class="r">Theme<span class="v">Dark ⌃</span></div>
        <div class="swatches">${["#ff6a3d", "#7c8cff", "#2dd4a7", "#f5c542", "#ff5c8a", "#4cc3ff", "#a78bfa"].map((c, i) => `<i class="${i === 0 ? "on" : ""}" style="background:${c}"></i>`).join("")}</div></div>
      <div class="h">Home sections</div>
      <div class="g"><div class="r">Listen again<div class="sw on"></div></div><div class="r">Picked for you<div class="sw on"></div></div><div class="r">Trending<div class="sw"></div></div></div>
    </div>`),
};

const name = (location.hash || "#home").slice(1);
document.body.innerHTML = (SCREENS[name] || SCREENS.home)();
