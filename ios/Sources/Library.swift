import SwiftUI

struct Playlist: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var tracks: [Track]
}

private struct LibraryData: Codable {
    var likes: [Track]
    var history: [Track]
    var playlists: [Playlist]
    var plays: [PlayEvent]
    var dislikes: [Track]
    var saved: [Coll]

    enum CodingKeys: String, CodingKey { case likes, history, playlists, plays, dislikes, saved }
    init(likes: [Track], history: [Track], playlists: [Playlist], plays: [PlayEvent], dislikes: [Track], saved: [Coll]) {
        self.likes = likes
        self.history = history
        self.playlists = playlists
        self.plays = plays
        self.dislikes = dislikes
        self.saved = saved
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        likes = try c.decodeIfPresent([Track].self, forKey: .likes) ?? []
        history = try c.decodeIfPresent([Track].self, forKey: .history) ?? []
        playlists = try c.decodeIfPresent([Playlist].self, forKey: .playlists) ?? []
        plays = try c.decodeIfPresent([PlayEvent].self, forKey: .plays) ?? []
        dislikes = try c.decodeIfPresent([Track].self, forKey: .dislikes) ?? []
        saved = try c.decodeIfPresent([Coll].self, forKey: .saved) ?? []
    }
}

/// Likes, listening history and playlists. Kept in one JSON file in the app's private storage.
@MainActor
final class Library: ObservableObject {
    @Published private(set) var likes: [Track] = [] { didSet { likedIDs = Set(likes.map { $0.id }) } }
    private(set) var likedIDs = Set<String>()
    @Published private(set) var history: [Track] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var plays: [PlayEvent] = []
    @Published private(set) var dislikes: [Track] = [] { didSet { dislikedIDs = Set(dislikes.map { $0.id }) } }
    private(set) var dislikedIDs = Set<String>()
    @Published private(set) var saved: [Coll] = []

    private let file: URL

    init() {
        let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        file = (dir ?? FileManager.default.temporaryDirectory).appendingPathComponent("library.json")
        if let d = try? Data(contentsOf: file), let l = try? JSONDecoder().decode(LibraryData.self, from: d) {
            likes = l.likes
            history = l.history
            playlists = l.playlists
            plays = l.plays
            dislikes = l.dislikes
            saved = l.saved
        }
    }

    private func save() {
        let d = LibraryData(likes: likes, history: history, playlists: playlists, plays: plays, dislikes: dislikes, saved: saved)
        if let data = try? JSONEncoder().encode(d) { try? data.write(to: file, options: .atomic) }
    }

    func isLiked(_ t: Track) -> Bool { likedIDs.contains(t.id) }
    func isDisliked(_ t: Track) -> Bool { dislikedIDs.contains(t.id) }

    /// "Don't suggest this again". Returns true when the song is marked afterwards.
    @discardableResult
    func toggleDislike(_ t: Track) -> Bool {
        let now: Bool
        if isDisliked(t) { dislikes.removeAll { $0.id == t.id }; now = false }
        else { dislikes.insert(t, at: 0); if dislikes.count > 300 { dislikes.removeLast(dislikes.count - 300) }; now = true }
        save()
        return now
    }

    func isSaved(_ c: Coll) -> Bool { saved.contains { $0.kind == c.kind && $0.id == c.id } }
    /// Saves or removes an album, playlist or artist. Returns true when it is saved afterwards.
    @discardableResult
    func toggleSaved(_ c: Coll) -> Bool {
        let now: Bool
        if isSaved(c) { saved.removeAll { $0.kind == c.kind && $0.id == c.id }; now = false } else { saved.insert(c, at: 0); now = true }
        save()
        return now
    }

    /// Returns true when the song is liked afterwards.
    @discardableResult
    func toggleLike(_ t: Track) -> Bool {
        let now: Bool
        if isLiked(t) { likes.removeAll { $0.id == t.id }; now = false } else { likes.insert(t, at: 0); now = true }
        save()
        return now
    }

    func addHistory(_ t: Track) {
        history.removeAll { $0.id == t.id }
        history.insert(t, at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
        save()
    }
    func clearHistory() { history = []; save() }
    func clearPlays() { plays = []; save() }

    /// Called when a song stops playing (finished or skipped) after at least a few seconds.
    func recordPlay(_ t: Track, seconds: Double) {
        plays.append(PlayEvent(id: t.id, title: t.title, artist: t.artist, at: Date(), secs: seconds))
        if plays.count > 5000 { plays.removeFirst(plays.count - 5000) }
        save()
    }

    @discardableResult
    func newPlaylist(_ name: String, with t: Track? = nil) -> Playlist {
        let clean = name.trimmingCharacters(in: .whitespaces)
        let p = Playlist(name: clean.isEmpty ? "New playlist" : clean, tracks: t.map { [$0] } ?? [])
        playlists.insert(p, at: 0)
        save()
        return p
    }
    /// False when the song was already in the playlist.
    @discardableResult
    func add(_ t: Track, to id: UUID) -> Bool {
        guard let i = playlists.firstIndex(where: { $0.id == id }), !playlists[i].tracks.contains(where: { $0.id == t.id }) else { return false }
        playlists[i].tracks.append(t)
        save()
        return true
    }
    func remove(_ t: Track, from id: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].tracks.removeAll { $0.id == t.id }
        save()
    }
    func rename(_ id: UUID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].name = clean
        save()
    }
    func deletePlaylist(_ id: UUID) { playlists.removeAll { $0.id == id }; save() }
    func playlist(_ id: UUID) -> Playlist? { playlists.first { $0.id == id } }

    struct ImportResult { var likes = 0, history = 0, playlists = 0, plays = 0, settings = 0 }

    /// Reads a backup file made by the YT Music web app and merges its likes, history and playlists in. Nothing is replaced.
    func importWebBackup(_ file: Data) throws -> ImportResult {
        guard let root = try JSONSerialization.jsonObject(with: file) as? [String: Any],
              (root["app"] as? String) == "yt-music", let data = root["data"] as? [String: Any] else {
            throw NSError(domain: "import", code: 1, userInfo: [NSLocalizedDescriptionKey: "That isn't a YT Music backup file"])
        }
        // each part is stored as a JSON string inside the file
        func part(_ key: String) -> Any? {
            guard let s = data[key] as? String, let d = s.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: d)
        }
        func tracks(_ any: Any?) -> [Track] {
            guard let arr = any as? [Any], let d = try? JSONSerialization.data(withJSONObject: arr),
                  let raw = try? JSONDecoder().decode([RawTrack].self, from: d) else { return [] }
            return raw.compactMap { Track($0) }
        }
        var out = ImportResult()
        let known = Set(likes.map { $0.id })
        let newLikes = tracks(part("likes")).filter { !known.contains($0.id) }
        likes.append(contentsOf: newLikes)                      // the web app lists newest first, and so do we
        out.likes = newLikes.count
        let seen = Set(history.map { $0.id })
        let newHist = tracks(part("history")).filter { !seen.contains($0.id) }
        history.append(contentsOf: newHist)
        out.history = newHist.count
        if let lib = part("library") as? [String: Any], let pls = lib["playlists"] as? [[String: Any]] {
            for p in pls {
                let name = (p["name"] as? String) ?? "Imported playlist"
                if playlists.contains(where: { $0.name == name }) { continue }
                playlists.append(Playlist(name: name, tracks: tracks(p["tracks"])))
                out.playlists += 1
            }
        }

        // songs marked "not interested", saved albums, playlists and artists, and the Mix genres
        let knownBad = Set(dislikes.map { $0.id })
        dislikes.append(contentsOf: tracks(part("dislikes")).filter { !knownBad.contains($0.id) })
        if let lib = part("library") as? [String: Any], let sv = lib["saved"] as? [[String: Any]],
           let d = try? JSONSerialization.data(withJSONObject: sv), let colls = try? JSONDecoder().decode([Coll].self, from: d) {
            for c in colls where !isSaved(c) && ["album", "playlist", "artist"].contains(c.kind) { saved.append(c) }
        }
        if let gs = part("genres") as? [[String: Any]] {
            let names = gs.compactMap { $0["name"] as? String }
            let cur = (UserDefaults.standard.string(forKey: "mixGenres") ?? "").split(separator: "|").map(String.init)
            let merged = cur + names.filter { !cur.contains($0) && !$0.contains("|") }
            UserDefaults.standard.set(merged.joined(separator: "|"), forKey: "mixGenres")
            out.settings += names.isEmpty ? 0 : 1
        }

        // listening stats: { log: [[epoch seconds, video id, seconds heard]], meta: { id: [title, artists, thumbnail, artist id] } }
        if let stats = part("stats") as? [String: Any], let log = stats["log"] as? [[Any]], let meta = stats["meta"] as? [String: [Any]] {
            let have = Set(plays.map { "\($0.id)|\(Int($0.at.timeIntervalSince1970))" })
            var added: [PlayEvent] = []
            for e in log where e.count >= 3 {
                guard let at = (e[0] as? NSNumber)?.doubleValue, let id = e[1] as? String, let secs = (e[2] as? NSNumber)?.doubleValue else { continue }
                if have.contains("\(id)|\(Int(at))") { continue }
                let m = meta[id] ?? []
                added.append(PlayEvent(id: id, title: (m.first as? String) ?? "", artist: (m.count > 1 ? m[1] as? String : nil) ?? "", at: Date(timeIntervalSince1970: at), secs: secs))
            }
            plays = (plays + added).sorted { $0.at < $1.at }
            if plays.count > 5000 { plays.removeFirst(plays.count - 5000) }
            out.plays = added.count
        }

        // the settings that exist here too: accent colour and non-music skipping
        if let s = part("settings") as? [String: Any] {
            if let a = s["accent"] as? String, a.hasPrefix("#"), a.count == 7 { UserDefaults.standard.set(a, forKey: "accent"); out.settings += 1 }
            if let sb = s["sponsorBlock"] as? Bool { UserDefaults.standard.set(sb, forKey: "sponsorBlock"); out.settings += 1 }
        }
        save()
        return out
    }
}


// MARK: backup file in the web app's format, so the web app can restore it too
extension Library {
    /// Everything the web app's "Back up to a file" holds that this app has too.
    func exportWebBackup() -> Data {
        func webTrack(_ t: Track) -> [String: Any] {
            var d: [String: Any] = ["videoId": t.id, "title": t.title, "duration": clock(Double(t.seconds)),
                                    "artists": t.artist.components(separatedBy: ", ").filter { !$0.isEmpty }]
            if let a = t.album { d["album"] = a }
            if let u = t.thumbnail { d["thumbnail"] = u.absoluteString }
            if t.video == true { d["video"] = true }
            return d
        }
        func json(_ o: Any) -> String {
            guard let d = try? JSONSerialization.data(withJSONObject: o), let s = String(data: d, encoding: .utf8) else { return "[]" }
            return s
        }
        let real = { (l: [Track]) in l.filter { $0.id.count >= 6 }.map(webTrack) }
        let ms = { (d: Date) in Int(d.timeIntervalSince1970 * 1000) }

        var meta: [String: [String]] = [:]
        var log: [[Any]] = []
        for p in plays where p.id.count >= 6 {
            log.append([Int(p.at.timeIntervalSince1970), p.id, Int(p.secs)])
            meta[p.id] = [p.title, p.artist, "", ""]
        }
        let genres: [[String: String]] = (UserDefaults.standard.string(forKey: "mixGenres") ?? "").split(separator: "|").map(String.init).map { name in
            var slug = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            slug = String(slug.prefix(60))
            return ["id": slug.isEmpty ? "genre" : slug, "name": name]
        }
        let playlistsOut: [[String: Any]] = playlists.map { p in
            ["id": "L" + String(p.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).lowercased(), "name": p.name, "tracks": real(p.tracks), "at": ms(Date())]
        }
        let savedOut: [[String: Any]] = saved.map { c in
            var d: [String: Any] = ["kind": c.kind, "id": c.id, "title": c.title, "subtitle": c.subtitle ?? "", "at": ms(Date())]
            if let t = c.thumbnail { d["thumbnail"] = t }
            return d
        }
        var settings: [String: Any] = ["sponsorBlock": UserDefaults.standard.bool(forKey: "sponsorBlock")]
        if let a = UserDefaults.standard.string(forKey: "accent"), a.hasPrefix("#") { settings["accent"] = a }

        let data: [String: String] = [
            "likes": json(real(likes)),
            "dislikes": json(real(dislikes)),
            "history": json(real(history)),
            "library": json(["playlists": playlistsOut, "saved": savedOut] as [String: Any]),
            "stats": json(["log": log, "meta": meta] as [String: Any]),
            "genres": json(genres),
            "settings": json(settings),
        ]
        let file: [String: Any] = ["app": "yt-music", "version": 1, "at": ISO8601DateFormatter().string(from: Date()), "data": data]
        return (try? JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted])) ?? Data()
    }
}
