import SwiftUI

/// Songs saved for offline listening: an .m4a file plus a small .json with the song's details, in the app's private storage.
@MainActor
final class Downloads: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    private let dir: URL

    init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        var d = base.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true                           // big files; they can be downloaded again
        try? d.setResourceValues(rv)
        dir = d
        reload()
    }

    func url(for id: String) -> URL? {
        let u = dir.appendingPathComponent("\(id).m4a")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    func has(_ id: String) -> Bool { url(for: id) != nil }

    /// Moves a finished download into place.
    func adopt(_ tmp: URL, track: Track) throws {
        let dest = dir.appendingPathComponent("\(track.id).m4a")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        try JSONEncoder().encode(track).write(to: dir.appendingPathComponent("\(track.id).json"), options: .atomic)
        tracks.removeAll { $0.id == track.id }
        tracks.insert(track, at: 0)
    }

    func remove(_ t: Track) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(t.id).m4a"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(t.id).json"))
        tracks.removeAll { $0.id == t.id }
    }

    private func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var found: [(Date, Track)] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f), let t = try? JSONDecoder().decode(Track.self, from: data), has(t.id) else { continue }
            let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            found.append((date, t))
        }
        tracks = found.sorted { $0.0 > $1.0 }.map { $0.1 }
    }
}
