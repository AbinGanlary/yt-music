import Foundation
import SwiftUI

/// Writes title, artist, album and cover art into an .m4a so the file looks right in Files, Music and any other player.
/// Only the 'moov' box is rewritten (a new 'udta' holding iTunes-style tags); the audio data is copied untouched.
enum M4ATagger {
    private struct Box {
        let type: String
        let start: Int
        let end: Int
        let head: Int
    }

    private static func u32(_ n: Int) -> [UInt8] {
        [UInt8((n >> 24) & 255), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)]
    }
    /// Four single bytes, so "©nam" is 0xA9 6E 61 6D.
    private static func tag4(_ s: String) -> [UInt8] { s.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) } }
    private static func box(_ type: String, _ kids: [UInt8]...) -> [UInt8] {
        let body = kids.flatMap { $0 }
        return u32(body.count + 8) + tag4(type) + body
    }
    private static func dataBox(_ flags: Int, _ bytes: [UInt8]) -> [UInt8] { box("data", u32(flags), u32(0), bytes) }
    private static func text(_ key: String, _ s: String) -> [UInt8] { box(key, dataBox(1, Array(s.utf8))) }

    private static func be32(_ b: [UInt8], _ i: Int) -> Int {
        (Int(b[i]) << 24) | (Int(b[i + 1]) << 16) | (Int(b[i + 2]) << 8) | Int(b[i + 3])
    }
    private static func be64(_ b: [UInt8], _ i: Int) -> Int {
        var v = 0
        for k in 0..<8 { v = (v << 8) | Int(b[i + k]) }
        return v
    }
    private static func put(_ b: inout [UInt8], _ i: Int, _ v: Int, bytes: Int) {
        for k in 0..<bytes { b[i + k] = UInt8((v >> (8 * (bytes - 1 - k))) & 255) }
    }

    /// The boxes inside b[from, to).
    private static func boxes(_ b: [UInt8], _ from: Int, _ to: Int) -> [Box] {
        var out: [Box] = []
        var p = from
        while p + 8 <= to {
            var size = be32(b, p)
            var head = 8
            let type = String(decoding: b[(p + 4)..<(p + 8)], as: UTF8.self)
            if size == 1 {
                guard p + 16 <= to else { break }
                size = be64(b, p + 8)
                head = 16
            } else if size == 0 {
                size = to - p
            }
            if size < head || p + size > to { break }
            out.append(Box(type: type, start: p, end: p + size, head: head))
            p += size
        }
        return out
    }

    /// Adds delta to every chunk offset (stco/co64) in a moov box that starts at index 0 of `m`.
    private static func shiftOffsets(_ m: inout [UInt8], delta: Int) {
        func walk(_ b: Box) {
            for k in boxes(m, b.start + b.head, b.end) {
                if ["trak", "mdia", "minf", "stbl"].contains(k.type) {
                    walk(k)
                } else if k.type == "stco" || k.type == "co64" {
                    let n = be32(m, k.start + k.head + 4)
                    let w = k.type == "stco" ? 4 : 8
                    for i in 0..<n {
                        let at = k.start + k.head + 8 + i * w
                        let v = w == 4 ? be32(m, at) : be64(m, at)
                        put(&m, at, v + delta, bytes: w)
                    }
                }
            }
        }
        walk(Box(type: "moov", start: 0, end: m.count, head: 8))
    }

    /// The tagged file, or the original bytes when it isn't a plain mp4 that can be tagged.
    static func tag(_ file: Data, title: String, artist: String, album: String?, cover: Data?) -> Data {
        let buf = [UInt8](file)
        let top = boxes(buf, 0, buf.count)
        guard top.contains(where: { $0.type == "ftyp" }), let moov = top.first(where: { $0.type == "moov" }) else { return file }

        var items: [[UInt8]] = []
        if !title.isEmpty { items.append(text("\u{A9}nam", title)) }
        if !artist.isEmpty {
            items.append(text("\u{A9}ART", artist))
            items.append(text("aART", artist))
        }
        if let a = album, !a.isEmpty { items.append(text("\u{A9}alb", a)) }
        if let c = cover, c.count > 8 {
            let png = c[c.startIndex] == 0x89
            items.append(box("covr", dataBox(png ? 14 : 13, [UInt8](c))))
        }
        if items.isEmpty { return file }

        let hdlr = box("hdlr", u32(0), u32(0), tag4("mdir"), tag4("appl"), u32(0), u32(0), [0])
        let ilst = items.reduce([UInt8]()) { $0 + $1 }
        let udta = box("udta", box("meta", u32(0), hdlr, box("ilst", ilst)))

        let kept = boxes(buf, moov.start + moov.head, moov.end).filter { $0.type != "udta" }.flatMap { Array(buf[$0.start..<$0.end]) }
        var newMoov = box("moov", kept, udta)
        let delta = newMoov.count - (moov.end - moov.start)
        if delta != 0 && top.contains(where: { $0.type == "mdat" && $0.start > moov.start }) { shiftOffsets(&newMoov, delta: delta) }

        var out = Data(buf[0..<moov.start])
        out.append(contentsOf: newMoov)
        out.append(contentsOf: buf[moov.end...])
        return out
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// The system share sheet: "Save to Files" is one of its actions.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
