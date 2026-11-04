// Swipe gestures. Song rows: right = like, left = play next (in the queue: remove). Mini player: left = next, right = previous.
import * as P from "./player.js";
import { toast, byId } from "./ui.js";
import { toggleLike } from "./sheets.js";

const MIN = 72, SLOP = 10, MAX_PULL = 96;
let g = null, swallowUntil = 0;

const rowOf = (el) => el.closest(".qrow[data-act=play],.qrow[data-act=qgo]");

document.addEventListener("touchstart", (e) => {
  g = null;
  if (e.touches.length !== 1 || e.target.closest("input,.switch")) return;
  const mini = e.target.closest("#mini"), el = mini || rowOf(e.target);
  if (!el) return;
  const t = e.touches[0];
  g = { el, mini: !!mini, x: t.clientX, y: t.clientY, dx: 0, lock: null };
}, { passive: true });

document.addEventListener("touchmove", (e) => {
  if (!g) return;
  const t = e.touches[0], dx = t.clientX - g.x, dy = t.clientY - g.y;
  if (!g.lock) {
    if (Math.max(Math.abs(dx), Math.abs(dy)) < SLOP) return;
    if (Math.abs(dx) > Math.abs(dy) * 1.4) { g.lock = "x"; g.el.style.transition = "none"; }
    else { g = null; return; }
  }
  g.dx = dx;
  const pull = Math.max(-MAX_PULL, Math.min(MAX_PULL, dx * 0.6));
  g.el.style.transform = `translateX(${pull}px)`;
  const hit = Math.abs(dx) >= MIN;
  g.el.classList.toggle("swipe-r", hit && dx > 0);
  g.el.classList.toggle("swipe-l", hit && dx < 0);
}, { passive: true });

document.addEventListener("touchend", () => {
  if (!g) return;
  const { el, mini, dx, lock } = g;
  g = null;
  if (lock !== "x") return;
  swallowUntil = Date.now() + 400;                       // the finger lift would otherwise count as a tap on the row
  el.style.transition = "transform .2s var(--ease)";
  el.style.transform = "";
  el.classList.remove("swipe-r", "swipe-l");
  setTimeout(() => { el.style.transition = ""; }, 220);
  if (Math.abs(dx) < MIN) return;
  const right = dx > 0;
  if (mini) { if (P.current()) right ? P.prev() : P.next(); return; }
  const inQueue = el.dataset.act === "qgo", i = Number(el.dataset.i);
  const track = inQueue ? P.state.queue[i] : byId(el.dataset.id);
  if (!track) return;
  if (right) toggleLike(track);
  else if (inQueue) { if (i !== P.state.idx) { P.removeAt(i); toast("Removed from queue"); } }
  else { P.playNext(track); toast(`Playing next: ${track.title}`); }
}, { passive: true });

document.addEventListener("touchcancel", () => {
  if (!g) return;
  g.el.style.transition = ""; g.el.style.transform = ""; g.el.classList.remove("swipe-r", "swipe-l");
  g = null;
}, { passive: true });

document.addEventListener("click", (e) => {
  if (Date.now() < swallowUntil) { e.stopPropagation(); e.preventDefault(); }
}, true);
