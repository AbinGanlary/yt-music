import Foundation

/// A song as Last.fm lists it: a title and an artist, with no audio. It is matched to a YouTube Music song to be played.
struct LFMTrack: Hashable, Sendable {
    let title: String
    let artist: String
    var image: URL? = nil
}

struct LFMAlbum: Hashable, Sendable {
    let title: String
    let artist: String
    var image: URL? = nil
}

struct LFMArtist: Hashable, Sendable {
    let name: String
    var image: URL? = nil
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
    /// Last.fm answers with this one picture when it has no real image (it stopped serving most artist and track pictures in 2019).
    static let placeholderImage = "2a96cbd8b46e442fc41c2b86b821562f"

    /// The key you pasted in Settings. It stays on this phone.
    static var key: String { (UserDefaults.standard.string(forKey: "lastfmKey") ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    static var isOn: Bool { !key.isEmpty }
    /// "youtube" or "lastfm": the music source chosen in Settings.
    static var source: String { UserDefaults.standard.string(forKey: "musicSource") ?? "youtube" }
    /// True when Last.fm is the chosen source and a key is set. Then Home, Explore, Mix and radio all use Last.fm.
    static var active: Bool { isOn && source == "lastfm" }

    // MARK: addresses and answers

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

    private static func root(_ data: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }

    /// Last.fm sends one item as an object and several as a list.
    private static func objects(_ any: Any?) -> [[String: Any]] {
        if let a = any as? [[String: Any]] { return a }
        if let d = any as? [String: Any] { return [d] }
        return []
    }

    private static func name(of any: Any?) -> String {
        if let d = any as? [String: Any] { return (d["name"] as? String) ?? "" }
        return (any as? String) ?? ""
    }

    /// The best real picture in a Last.fm "image" list, or nil when it only has the placeholder.
    static func bestImage(_ any: Any?) -> URL? {
        var bySize: [String: String] = [:]
        for d in objects(any) {
            if let u = d["#text"] as? String, !u.isEmpty, let s = d["size"] as? String { bySize[s] = u }
        }
        for size in ["extralarge", "mega", "large", "medium", "small"] {
            if let u = bySize[size], !u.contains(placeholderImage) { return URL(string: u.replacingOccurrences(of: "http://", with: "https://")) }
        }
        return nil
    }

    /// Songs from a chart, tag, artist or "similar tracks" answer.
    static func parseTracks(_ data: Data) -> [LFMTrack] {
        guard let r = root(data) else { return [] }
        let holder = ["tracks", "similartracks", "toptracks"].compactMap { r[$0] as? [String: Any] }.first
        var seen = Set<String>()
        return objects(holder?["track"]).compactMap { d in
            guard let title = d["name"] as? String, !title.isEmpty else { return nil }
            let artist = name(of: d["artist"])
            guard !artist.isEmpty, seen.insert(title.lowercased() + "|" + artist.lowercased()).inserted else { return nil }
            return LFMTrack(title: title, artist: artist, image: bestImage(d["image"]))
        }
    }

    static func parseAlbums(_ data: Data) -> [LFMAlbum] {
        guard let r = root(data) else { return [] }
        let holder = ["albums", "topalbums"].compactMap { r[$0] as? [String: Any] }.first
        return objects(holder?["album"]).compactMap { d in
            guard let title = d["name"] as? String, !title.isEmpty, title != "(null)" else { return nil }
            return LFMAlbum(title: title, artist: name(of: d["artist"]), image: bestImage(d["image"]))
        }
    }

    static func parseArtists(_ data: Data) -> [LFMArtist] {
        guard let r = root(data) else { return [] }
        let holder = ["artists", "topartists", "similarartists"].compactMap { r[$0] as? [String: Any] }.first
        return objects(holder?["artist"]).compactMap { d in
            guard let n = d["name"] as? String, !n.isEmpty else { return nil }
            return LFMArtist(name: n, image: bestImage(d["image"]))
        }
    }

    static func parseTags(_ data: Data) -> [String] {
        guard let r = root(data), let tags = (r["tags"] as? [String: Any])?["tag"] as? [[String: Any]] else { return [] }
        return tags.compactMap { $0["name"] as? String }
    }

    /// An album's details and its songs (each song carries the album's cover).
    static func parseAlbumInfo(_ data: Data) -> (album: LFMAlbum, tracks: [LFMTrack])? {
        guard let r = root(data), let a = r["album"] as? [String: Any], let title = a["name"] as? String else { return nil }
        let artist = name(of: a["artist"])
        let cover = bestImage(a["image"])
        let tracks = objects((a["tracks"] as? [String: Any])?["track"]).compactMap { d -> LFMTrack? in
            guard let t = d["name"] as? String, !t.isEmpty else { return nil }
            let who = name(of: d["artist"])
            return LFMTrack(title: t, artist: who.isEmpty ? artist : who, image: cover)
        }
        return (LFMAlbum(title: title, artist: artist, image: cover), tracks)
    }

    /// The cover of the album a song is on.
    static func parseTrackArt(_ data: Data) -> URL? {
        guard let r = root(data), let t = r["track"] as? [String: Any], let a = t["album"] as? [String: Any] else { return nil }
        return bestImage(a["image"])
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
        guard let n = countryName(code) else { return try await chart(limit: limit) }
        return parseTracks(try await fetch("geo.getTopTracks", ["country": n, "limit": String(limit)]))
    }
    /// The top artists: worldwide, or in a country when one is chosen in Settings.
    static func topArtists(limit: Int = 20) async throws -> [LFMArtist] {
        let loc = EngineHost.loc()
        if !loc.isEmpty, let n = countryName(loc) {
            return parseArtists(try await fetch("geo.getTopArtists", ["country": n, "limit": String(limit)]))
        }
        return parseArtists(try await fetch("chart.getTopArtists", ["limit": String(limit)]))
    }
    /// The top tracks for a tag such as "indie" or "lo-fi".
    static func tag(_ tag: String, limit: Int = 50) async throws -> [LFMTrack] {
        parseTracks(try await fetch("tag.getTopTracks", ["tag": tag, "limit": String(limit)]))
    }
    static func tagAlbums(_ tag: String, limit: Int = 24) async throws -> [LFMAlbum] {
        parseAlbums(try await fetch("tag.getTopAlbums", ["tag": tag, "limit": String(limit)]))
    }
    /// Last.fm has no "new releases" feed. Albums that listeners tag with this year are the closest thing.
    static func newAlbums(limit: Int = 24) async throws -> [LFMAlbum] {
        let year = Calendar.current.component(.year, from: Date())
        var out = try await tagAlbums(String(year), limit: limit)
        if out.count < 8 { out += try await tagAlbums(String(year - 1), limit: limit) }
        var seen = Set<String>()
        return out.filter { seen.insert($0.title.lowercased() + "|" + $0.artist.lowercased()).inserted }
    }
    /// Songs that listeners of this song also play.
    static func similar(artist: String, track: String, limit: Int = 30) async throws -> [LFMTrack] {
        parseTracks(try await fetch("track.getSimilar", ["artist": artist, "track": track, "limit": String(limit), "autocorrect": "1"]))
    }
    static func artistTopTracks(_ artist: String, limit: Int = 20) async throws -> [LFMTrack] {
        parseTracks(try await fetch("artist.getTopTracks", ["artist": artist, "limit": String(limit), "autocorrect": "1"]))
    }
    static func artistTopAlbums(_ artist: String, limit: Int = 12) async throws -> [LFMAlbum] {
        parseAlbums(try await fetch("artist.getTopAlbums", ["artist": artist, "limit": String(limit), "autocorrect": "1"]))
    }
    static func similarArtists(_ artist: String, limit: Int = 12) async throws -> [LFMArtist] {
        parseArtists(try await fetch("artist.getSimilar", ["artist": artist, "limit": String(limit), "autocorrect": "1"]))
    }
    static func albumInfo(artist: String, album: String) async throws -> (album: LFMAlbum, tracks: [LFMTrack])? {
        parseAlbumInfo(try await fetch("album.getInfo", ["artist": artist, "album": album, "autocorrect": "1"]))
    }
    static func trackArt(artist: String, track: String) async throws -> URL? {
        parseTrackArt(try await fetch("track.getInfo", ["artist": artist, "track": track, "autocorrect": "1"]))
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

/// Turns Last.fm songs into playable YouTube Music songs, remembering the answers. With Last.fm as the source, the song
/// also gets Last.fm's album cover.
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
              var found = SongMatch.pick(Array(results.prefix(6)), title: l.title, artist: l.artist) else { return nil }
        var cover = l.image
        if cover == nil && LastFM.active { cover = try? await LastFM.trackArt(artist: l.artist, track: l.title) }
        if let c = cover { found.thumbnail = c }
        cache[key] = found
        return found
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
