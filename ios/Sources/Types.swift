import Foundation

/// A resized Google image address (covers come as =w60-h60… and similar).
func sizedURL(_ s: String?, _ px: Int = 400) -> URL? {
    guard let s = s else { return nil }
    let sized = s.replacingOccurrences(of: "=w\\d+-h\\d+.*$", with: "=w\(px)-h\(px)-l90-rj", options: .regularExpression)
    return URL(string: sized)
}

/// An album, playlist or artist card.
struct Coll: Codable, Identifiable, Hashable {
    let kind: String
    let id: String
    let title: String
    let subtitle: String?
    let thumbnail: String?
    var url: URL? { sizedURL(thumbnail, 400) }
}

/// An album, playlist or artist page.
struct PageData: Decodable {
    let kind: String?
    let title: String?
    let thumbnail: String?
    let subtitle: String?
    let meta: String?
    let tracks: [RawTrack]?
    let albums: [Coll]?
    let radioVideoId: String?
}

struct MoodItem: Decodable, Hashable {
    let title: String
    let params: String
}
struct MoodSection: Decodable, Hashable {
    let section: String
    let items: [MoodItem]
}
struct ExploreData: Decodable {
    let newReleases: [Coll]
    let moods: [MoodSection]
}
struct GenreData: Decodable {
    let songs: [RawTrack]
    let playlists: [Coll]
}
struct ChartsData: Decodable {
    let playlists: [Coll]
    let artists: [Coll]
}

struct LyricLine: Decodable {
    let text: String
    let start: Double?
    let end: Double?
}
struct Lyrics: Decodable {
    let lyrics: String?
    let lines: [LyricLine]?
    let source: String?
    let hasTimestamps: Bool?
}

/// One finished or skipped play, for the Analytics tab.
struct PlayEvent: Codable {
    let id: String
    let title: String
    let artist: String
    let at: Date
    let secs: Double
}
