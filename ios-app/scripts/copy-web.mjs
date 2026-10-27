// Copies the web UI (../frontend) into www/ so Capacitor can bundle it inside the app.
import { cpSync, rmSync, mkdirSync, existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const src = resolve(here, "../../frontend");
const dst = resolve(here, "../www");
if (!existsSync(src)) { console.error("frontend folder not found:", src); process.exit(1); }
rmSync(dst, { recursive: true, force: true });
mkdirSync(dst, { recursive: true });
// The service worker is only for the website; inside the app everything is already bundled.
cpSync(src, dst, { recursive: true, filter: (p) => !p.endsWith("sw.js") });
console.log("web UI copied to", dst);
