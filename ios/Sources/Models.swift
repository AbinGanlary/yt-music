import SwiftUI

struct Track: Identifiable, Equatable, Hashable, Codable {
    let id: String            // YouTube video id
    let title: String
    let artist: String
    let seconds: Int
    var thumbnail: URL? = nil
    var album: String? = nil
    var video: Bool? = nil     // a music video rather than a song

    /// Colours used behind (or instead of) the cover.
    var colors: [Color] {
        let n = id.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 360 }
        let h = Double(n) / 360
        return [Color(hue: h, saturation: 0.75, brightness: 0.95), Color(hue: (h + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 0.6)]
    }
    var art: LinearGradient { LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing) }

    init(id: String, title: String, artist: String, seconds: Int, thumbnail: URL? = nil, album: String? = nil, video: Bool? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.seconds = seconds
        self.thumbnail = thumbnail
        self.album = album
        self.video = video
    }

    /// From the engine's JSON ("3:45" durations, a Google image address for the cover).
    init?(_ r: RawTrack) {
        guard let title = r.title, !title.isEmpty else { return nil }
        var secs = 0
        for part in (r.duration ?? "").split(separator: ":") { secs = secs * 60 + (Int(part) ?? 0) }
        self.init(id: r.videoId, title: title, artist: (r.artists ?? []).joined(separator: ", "), seconds: secs > 0 ? secs : 200, thumbnail: sizedURL(r.thumbnail, 400), album: r.album, video: r.video)
    }
}

/// A remote image cropped to fill whatever square it is given. (A 16:9 video thumbnail must not widen its parent.)
struct RemoteSquare: View {
    let url: URL?
    var body: some View {
        Color.clear
            .overlay {
                ZStack {
                    LinearGradient(colors: [Theme.surface, Theme.surface.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    if let u = url {
                        CachedImage(url: u)
                    }
                }
            }
            .clipped()
    }
}

/// Cover art: the real image when there is one, over a gradient so there is never a blank square.
struct Cover: View {
    let track: Track
    var radius: CGFloat = 8
    var body: some View {
        Color.clear
            .overlay {
                ZStack {
                    track.art
                    if let u = track.thumbnail {
                        CachedImage(url: u)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Shown until the engine has answered (and if it never does).
let sampleTracks: [Track] = [
    Track(id: "s1", title: "Midnight Drive", artist: "Neon Harbor", seconds: 214),
    Track(id: "s2", title: "Paper Planes", artist: "Lila Moreno", seconds: 187),
    Track(id: "s3", title: "Slow Burn", artist: "The Quiet Hours", seconds: 243),
    Track(id: "s4", title: "Golden Hour", artist: "Sunday Static", seconds: 201),
]
