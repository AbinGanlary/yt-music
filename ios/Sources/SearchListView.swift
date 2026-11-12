import SwiftUI

/// Search a list: paste several songs, check the best match for each line, then play them, queue them or save them as a playlist.
struct SearchListView: View {
    @EnvironmentObject var engine: EngineHost
    @EnvironmentObject var player: PlayerModel
    @Environment(\.dismiss) private var dismiss

    private struct Row: Identifiable {
        let id = UUID()
        let query: String
        var hits: [Track] = []
        var pick = 0
        var skip = false
        var chosen: Track? { hits.indices.contains(pick) && !skip ? hits[pick] : nil }
    }

    @State private var text = ""
    @State private var rows: [Row] = []
    @State private var phase = 0                  // 0 type the list, 1 searching, 2 check the matches
    @State private var progress = 0
    @State private var name = ""
    private let maxLines = 60

    private var chosen: [Track] { rows.compactMap { $0.chosen } }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case 0: input
                case 1: searching
                default: review
                }
            }
            .background(Theme.bg)
            .navigationTitle("Search a list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Close") { dismiss() } } }
        }
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("One song per line, for example “Excuses - AP Dhillon”. A CSV exported from another app works too.")
                .font(.footnote).foregroundStyle(Theme.muted)
            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(minHeight: 200)
            Button { Task { await search() } } label: {
                Text("Find songs").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(Theme.accent, in: Capsule()).foregroundStyle(Color.black)
            }
            .buttonStyle(.plain)
            .disabled(parse(text).isEmpty)
            Text("Each line is searched on YouTube Music and you check the best match before anything plays. Up to \(maxLines) songs.")
                .font(.caption).foregroundStyle(Theme.muted)
            Spacer()
        }
        .padding(20)
    }

    private var searching: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView()
            Text("Searching… \(progress) of \(rows.count)").font(.subheadline).foregroundStyle(Theme.muted)
            Spacer()
        }
    }

    private var review: some View {
        let list = chosen
        return List {
            Section {
                ForEach(rows.indices, id: \.self) { i in rowView(i) }
            } header: {
                Text("\(list.count) song\(list.count == 1 ? "" : "s") found")
                    .font(.title3.bold()).foregroundStyle(Color.primary).textCase(nil)
            } footer: {
                Text("Tap 1/4 to see the next match for a line, or the ✕ to leave a song out.")
            }

            Section {
                HStack(spacing: 10) {
                    Button { tap(); player.play(list[0], in: list); dismiss() } label: {
                        Label("Play all", systemImage: "play.fill").frame(maxWidth: .infinity).padding(.vertical, 11)
                            .background(Theme.accent, in: Capsule()).foregroundStyle(Color.black)
                    }
                    Button { tap(); list.forEach { player.addToQueue($0) }; dismiss() } label: {
                        Label("Add to queue", systemImage: "text.append").frame(maxWidth: .infinity).padding(.vertical, 11)
                            .background(Theme.surface, in: Capsule())
                    }
                }
                .buttonStyle(.plain)
                .disabled(list.isEmpty)
                .listRowBackground(Color.clear)
                TextField("Playlist name", text: $name)
                Button("Save as playlist") {
                    let p = player.lib.newPlaylist(name.isEmpty ? "Song list" : name)
                    list.forEach { player.lib.add($0, to: p.id) }
                    player.notify("Saved \(list.count) songs")
                    dismiss()
                }
                .disabled(list.isEmpty)
            }
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func rowView(_ i: Int) -> some View {
        let r = rows[i]
        if r.hits.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.query).font(.body.weight(.semibold)).lineLimit(1)
                Text("No match found").font(.subheadline).foregroundStyle(Theme.muted)
            }
            .opacity(0.65)
        } else {
            let t = r.hits[r.pick]
            HStack(spacing: 12) {
                Cover(track: t, radius: 8).frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).font(.body.weight(.semibold)).lineLimit(1)
                    Text("\(t.artist) · for “\(r.query)”").font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer()
                if r.hits.count > 1 {
                    Button { rows[i].pick = (r.pick + 1) % r.hits.count } label: {
                        Text("\(r.pick + 1)/\(r.hits.count)").font(.caption.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Theme.surface, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Button { rows[i].skip.toggle() } label: { Image(systemName: r.skip ? "plus.circle" : "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.muted)
            }
            .opacity(r.skip ? 0.4 : 1)
        }
    }

    private func search() async {
        let qs = Array(parse(text).prefix(maxLines))
        rows = qs.map { Row(query: $0) }
        progress = 0
        phase = 1
        let eng = engine
        var i = 0
        while i < qs.count {                                   // three searches at a time
            let batch = Array(i..<min(i + 3, qs.count))
            await withTaskGroup(of: (Int, [Track]).self) { group in
                for j in batch { group.addTask { (j, (try? await eng.search(qs[j])) ?? []) } }
                for await (j, hits) in group {
                    rows[j].hits = Array(hits.prefix(4))
                    progress += 1
                }
            }
            i += 3
        }
        phase = 2
    }

    // MARK: reading the pasted text

    /// One CSV line to cells, honouring "quoted, values".
    private func cells(_ line: String) -> [String] {
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
    private func parse(_ raw: String) -> [String] {
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
