// Routing: five tabs (Home, Mix, Explore, Library, Analytics) plus pages that stack on top (back button).
import { $, $$ } from "./ui.js";

export const view = $("#view");
let route = { name: "home" }, cur = "home", tabSel = "home";
const stack = [];
const renderers = {};

export const register = (name, fn) => { renderers[name] = fn; };
export const getCur = () => cur;
export const getRoute = () => route;
export const getTab = () => tabSel;
export const scroller = () => view.querySelector("main.scroll");

/** Sets the page: a header block and a scrolling main. Returns the main element. */
export function page(header, body, mainCls = "") {
  view.innerHTML = `${header}<main class="scroll ${mainCls}">${body}</main>`;
  return scroller();
}

function highlight() {
  $$("#tabs button, #side .navb[data-tab]").forEach((b) => b.classList.toggle("on", b.dataset.tab === tabSel));
}

export function show(r) {
  route = r; cur = r.name;
  highlight();
  renderers[r.name](r);
  scroller()?.scrollTo(0, 0);
}
export function navigate(r) {
  route.scroll = scroller()?.scrollTop || 0;
  stack.push(route);
  show(r);
}
export function back() {
  const r = stack.pop();
  if (!r) return show({ name: tabSel });
  show(r);
  requestAnimationFrame(() => scroller()?.scrollTo(0, r.scroll || 0));
}
export function setTab(t) { stack.length = 0; tabSel = t; show({ name: t }); }
/** Re-render the current page, keeping the scroll position. */
export function rerender() {
  const sc = scroller()?.scrollTop || 0;
  renderers[route.name](route);
  scroller()?.scrollTo(0, sc);
}
export const canGoBack = () => stack.length > 0;
