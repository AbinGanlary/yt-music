import Foundation

/// Turns pasted text (one song per line, or a CSV exported from another app) into search queries.
enum ListParser {
    /// One CSV line to cells, honouring "quoted, values".
    static func cells(_ line: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quoted = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { cur.append("\""); i += 1 } else { quoted = false }
                } else { cur.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == "," { out.append(cur); cur = "" }
            else { cur.append(c) }
            i += 1
        }
        out.append(cur)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Pasted text to search queries: plain lines, or the title and artist columns of a CSV.
    static func parse(_ raw: String) -> [String] {
        let lines = raw.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.first else { return [] }
        let head = cells(first).map { $0.lowercased() }
        if head.count > 1, let ti = head.firstIndex(where: { ["track", "song", "title", "track name", "song name"].contains($0) }) {
            let ai = head.firstIndex(where: { $0.contains("artist") })
            return lines.dropFirst().compactMap { l in
                let c = cells(l)
                guard ti < c.count else { return nil }
                let artist = ai.flatMap { $0 < c.count ? c[$0].components(separatedBy: CharacterSet(charactersIn: ";|")).first : nil } ?? ""
                return [c[ti], artist].filter { !$0.isEmpty }.joined(separator: " ")
            }.filter { !$0.isEmpty }
        }
        var seen = Set<String>()
        return lines.map { l in
            var s = l.replacingOccurrences(of: "^\\s*\\d+[.)]\\s*", with: "", options: .regularExpression)
            s = s.replacingOccurrences(of: "\\s+[-–—]\\s+", with: " ", options: .regularExpression)
            return s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
