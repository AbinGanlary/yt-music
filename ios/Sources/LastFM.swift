import Foundation

/// A song as Last.fm lists it: a title and an artist, with no audio. It is matched to a YouTube Music song to be played.
struct LFMTrack: Hashable, Sendable {
    let title: String
    let artist: String
}

enum LastFMError: LocalizedError {
    case noKey
    case api(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noKey: return "Add your Last.fm API key in Settings first."
        case .api(let m): return "Last.fm said: \(m)"
        case .badResponse: return "Last.fm didn't answer properly. Try again in a moment."
        }
    }
}

/// Last.fm's public API (read-only calls that need just an API key). Nothing here uses your Last.fm password.
enum LastFM {
    static let endpoint = "https://ws.audioscrobbler.com/2.0/"

    /// The key you pasted in Settings. It stays on this phone.
    static var key: String { (UserDefaults.standard.string(forKey: "lastfmKey") ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    static var isOn: Bool { !key.isEmpty }

    /// The request address for one API method.
    static func url(_ method: String, _ params: [String: String] = [:], key: String) -> URL? {
        guard var c = URLComponents(string: endpoint) else { return nil }
        var items = [URLQueryItem(name: "method", value: method), URLQueryItem(name: "api_key", value: key), URLQueryItem(name: "format", value: "json")]
        for (k, v) in params.sorted(by: { $0.key < $1.key }) { items.append(URLQueryItem(name: k, value: v)) }
        c.queryItems = items
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")      // "+" would otherwise read as a space
        return c.url
    }

    /// Last.fm reports problems as JSON ({"error": 10, "message": "Invalid API key"}), usually with a 4xx status.
    static func errorMessage(_ data: Data) -> String? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], o["error"] != nil else { return nil }
        return (o["message"] as? String) ?? "an error"
    }

    /// Songs from a chart, tag or "similar tracks" answer. Last.fm sends one song as an object and several as a list.
    static func parseTracks(_ data: Data) -> [LFMTrack] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        let holder = ["tracks", "similartracks", "toptracks"].compactMap { root[$0] as? [String: Any] }.first
        guard let raw = holder?["track"] else { return [] }
        let list: [[String: Any]] = (raw as? [[String: Any]]) ?? ((raw as? [String: Any]).map { [$0] } ?? [])
        var seen = Set<String>()
        return list.compactMap { d in
            guard let title = d["name"] as? String, !title.isEmpty else { return nil }
            let artist = (d["artist"] as? [String: Any])?["name"] as? String ?? (d["artist"] as? String) ?? ""
            guard !artist.isEmpty, seen.insert(title.lowercased() + "|" + artist.lowercased()).inserted else { return nil }
            return LFMTrack(title: title, artist: artist)
        }
    }

    static func parseTags(_ data: Data) -> [String] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tags = (root["tags"] as? [String: Any])?["tag"] as? [[String: Any]] else { return [] }
        return tags.compactMap { $0["name"] as? String }
    }

    /// Last.fm wants English country names ("India", "United Kingdom"), not codes.
    static func countryName(_ code: String) -> String? {
        Locale(identifier: "en_US").localizedString(forRegionCode: code.uppercased())
    }

    // MARK: the calls

    private static func fetch(_ method: String, _ params: [String: String] = [:]) async throws -> Data {
        guard isOn else { throw LastFMError.noKey }
        guard let u = url(method, params, key: key) else { throw LastFMError.badResponse }
        let (data, response) = try await URLSession.shared.data(from: u)
        if let m = errorMessage(data) { throw LastFMError.api(m) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw LastFMError.badResponse }
        return data
    }

    /// The worldwide top tracks right now.
    static func chart(limit: Int = 50) async throws -> [LFMTrack] {
        parseTracks(try await fetch("chart.getTopTracks", ["limit": String(limit)]))
    }
    /// The top tracks in a country (a code like "IN").
    static func country(_ code: String, limit: Int = 50) async throws -> [LFMTrack] {
        guard let name = countryName(code) else { return try await chart(limit: limit) }
        return parseTracks(try await fetch("geo.getTopTracks", ["country": name, "limit": String(limit)]))
    }
    /// The top tracks for a tag such as "indie" or "lo-fi".
    static func tag(_ tag: String, limit: Int = 50) async throws -> [LFMTrack] {
        parseTracks(try await fetch("tag.getTopTracks", ["tag": tag, "limit": String(limit)]))
    }
    /// Songs that listeners of this song also play.
    static func similar(artist: String, track: String, limit: Int = 30) async throws -> [LFMTrack] {
        parseTracks(try await fetch("track.getSimilar", ["artist": artist, "track": track, "limit": String(limit), "autocorrect": "1"]))
    }
    /// The most used tags.
    static func topTags(limit: Int = 14) async throws -> [String] {
        Array(parseTags(try await fetch("chart.getTopTags", ["limit": String(limit)])).prefix(limit))
    }
}

/// Picks the YouTube Music song that is the best match for a Last.fm song.
enum SongMatch {
    /// Lower case, without "(feat. …)" and "[Remastered]" parts or punctuation, so "Don't Stop (Remix)" and "dont stop" compare well.
    static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        t = t.replacingOccurrences(of: "\\([^)]*\\)|\\[[^\\]]*\\]", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func pick(_ candidates: [Track], title: String, artist: String) -> Track? {
        let wantTitle = normalize(title), wantArtist = normalize(artist)
        guard !wantTitle.isEmpty else { return candidates.first }
        func score(_ t: Track) -> Int {
            var s = 0
            let have = normalize(t.title)
            if have == wantTitle { s += 3 } else if !have.isEmpty, have.contains(wantTitle) || wantTitle.contains(have) { s += 2 }
            let a = normalize(t.artist)
            if !wantArtist.isEmpty, a.contains(wantArtist) || wantArtist.contains(a) || wantArtist.split(separator: " ").contains(where: { a.contains($0) && $0.count > 3 }) { s += 2 }
            return s
        }
        // the earliest result wins a tie: YouTube Music already ranks the search results
        var best: Track?
        var bestScore = -1
        for c in candidates where score(c) > bestScore { best = c; bestScore = score(c) }
        return best
    }
}

/// Turns Last.fm songs into playable YouTube Music songs, remembering the answers.
@MainActor
final class SongMatcher {
    static let shared = SongMatcher()
    private var cache: [String: Track] = [:]
    private let file: URL

    private init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        file = base.appendingPathComponent("lastfm-matches.json")
        if let d = try? Data(contentsOf: file), let c = try? JSONDecoder().decode([String: Track].self, from: d) { cache = c }
    }

    private func save() {
        if cache.count > 2_000 { cache.removeAll() }
        if let d = try? JSONEncoder().encode(cache) { try? d.write(to: file, options: .atomic) }
    }

    func resolve(_ l: LFMTrack) async -> Track? {
        let key = SongMatch.normalize(l.artist) + "|" + SongMatch.normalize(l.title)
        if let hit = cache[key] { return hit }
        guard let results = try? await EngineHost.shared.search("\(l.artist) \(l.title)"),
              let best = SongMatch.pick(Array(results.prefix(6)), title: l.title, artist: l.artist) else { return nil }
        cache[key] = best
        return best
    }

    /// The matched songs in Last.fm's order, four searches at a time. Songs with no match are left out.
    func resolveAll(_ list: [LFMTrack], max: Int = 20) async -> [Track] {
        let slice = Array(list.prefix(max))
        var found = [Track?](repeating: nil, count: slice.count)
        var i = 0
        while i < slice.count {
            if Task.isCancelled { break }
            let batch = Array(i..<min(i + 4, slice.count))
            await withTaskGroup(of: (Int, Track?).self) { group in
                for j in batch { group.addTask { (j, await self.resolve(slice[j])) } }
                for await (j, t) in group { found[j] = t }
            }
            i += 4
        }
        save()
        var seen = Set<String>()
        return found.compactMap { $0 }.filter { seen.insert($0.id).inserted }
    }
}
