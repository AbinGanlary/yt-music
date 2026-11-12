// Writes title, artist, album, year and cover art into an .m4a so the file looks right in Files, Music and any other player.
// Only the 'moov' box is rewritten (a new 'udta' with the iTunes-style tags); the audio data is copied untouched.
const enc = new TextEncoder();
const u32 = (n) => new Uint8Array([(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255]);
const cat = (...a) => { const o = new Uint8Array(a.reduce((s, x) => s + x.length, 0)); let p = 0; for (const x of a) { o.set(x, p); p += x.length; } return o; };
const tag4 = (t) => new Uint8Array([...t].map((c) => c.charCodeAt(0)));   // four single bytes, so "©nam" is 0xA9 6E 61 6D
const box = (type, ...kids) => { const body = cat(...kids); return cat(u32(body.length + 8), tag4(type), body); };
const dataBox = (flags, bytes) => box("data", u32(flags), u32(0), bytes);
const text = (key, s) => box(key, dataBox(1, enc.encode(s)));

/** The boxes inside buf[from, to): [{ type, start, end, head }] where head is 8 (or 16 for a 64-bit size). */
function boxes(buf, from, to) {
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength), out = [];
  for (let p = from; p + 8 <= to;) {
    let size = dv.getUint32(p), head = 8;
    const type = String.fromCharCode(buf[p + 4], buf[p + 5], buf[p + 6], buf[p + 7]);
    if (size === 1) { size = Number(dv.getBigUint64(p + 8)); head = 16; } else if (size === 0) size = to - p;
    if (size < head || p + size > to) break;
    out.push({ type, start: p, end: p + size, head });
    p += size;
  }
  return out;
}
const find = (buf, b, type) => boxes(buf, b.start + b.head, b.end).find((x) => x.type === type);

/** Adds `delta` to every chunk offset (stco/co64) inside moov: needed when moov sits before the audio data and grows. */
function shiftOffsets(buf, moov, delta) {
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  const walk = (b) => {
    for (const k of boxes(buf, b.start + b.head, b.end)) {
      if (["trak", "mdia", "minf", "stbl"].includes(k.type)) walk(k);
      else if (k.type === "stco" || k.type === "co64") {
        const n = dv.getUint32(k.start + k.head + 4), w = k.type === "stco" ? 4 : 8;
        for (let i = 0; i < n; i++) {
          const at = k.start + k.head + 8 + i * w;
          if (w === 4) dv.setUint32(at, dv.getUint32(at) + delta); else dv.setBigUint64(at, dv.getBigUint64(at) + BigInt(delta));
        }
      }
    }
  };
  walk(moov);
}

/** meta = { title, artist, album, year, cover (Uint8Array JPEG or PNG) }. Returns a new Blob, or the original if the file isn't a plain mp4. */
export async function tagM4a(blob, meta) {
  const buf = new Uint8Array(await blob.arrayBuffer());
  const top = boxes(buf, 0, buf.length);
  const moov = top.find((b) => b.type === "moov");
  if (!top.some((b) => b.type === "ftyp") || !moov) return blob;

  const items = [];
  if (meta.title) items.push(text("\xA9nam", meta.title));
  if (meta.artist) { items.push(text("\xA9ART", meta.artist)); items.push(text("aART", meta.artist)); }
  if (meta.album) items.push(text("\xA9alb", meta.album));
  if (meta.year) items.push(text("\xA9day", String(meta.year)));
  if (meta.cover?.length) items.push(box("covr", dataBox(meta.cover[0] === 0x89 ? 14 : 13, meta.cover)));
  if (!items.length) return blob;
  const hdlr = box("hdlr", u32(0), u32(0), tag4("mdir"), tag4("appl"), u32(0), u32(0), new Uint8Array([0]));
  const udta = box("udta", box("meta", u32(0), hdlr, box("ilst", ...items)));

  const inner = boxes(buf, moov.start + moov.head, moov.end).filter((b) => b.type !== "udta");
  const kept = inner.map((b) => buf.subarray(b.start, b.end));
  const newMoov = box("moov", ...kept, udta);
  const delta = newMoov.length - (moov.end - moov.start);
  const mdatAfter = top.some((b) => b.type === "mdat" && b.start > moov.start);

  if (delta !== 0 && mdatAfter) { const m = newMoov.slice(); shiftOffsets(m, { start: 0, head: 8, end: m.length }, delta); return new Blob([buf.subarray(0, moov.start), m, buf.subarray(moov.end)], { type: "audio/mp4" }); }
  return new Blob([buf.subarray(0, moov.start), newMoov, buf.subarray(moov.end)], { type: "audio/mp4" });
}

/** The cover as JPEG bytes (re-encoded through a canvas so any format works), or null if it can't be fetched. */
export async function coverBytes(url, size = 544) {
  if (!url) return null;
  try {
    const img = await new Promise((ok, no) => { const i = new Image(); i.crossOrigin = "anonymous"; i.onload = () => ok(i); i.onerror = no; i.src = url; });
    const c = document.createElement("canvas"); c.width = c.height = size;
    c.getContext("2d").drawImage(img, 0, 0, size, size);
    const b = await new Promise((r) => c.toBlob(r, "image/jpeg", 0.9));
    return b ? new Uint8Array(await b.arrayBuffer()) : null;
  } catch { return null; }
}
