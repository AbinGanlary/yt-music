import Testing
import Foundation
@testable import YTMusic

@MainActor
@Suite("The library")
struct LibraryTests {
    private func makeLibrary() -> (Library, URL) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString).json")
        return (Library(file: file), file)
    }

    private func song(_ id: String, _ title: String = "Song", artist: String = "Artist") -> Track {
        Track(id: id, title: title, artist: artist, seconds: 200)
    }

    @Test func likesToggleAndSurviveARestart() {
        let (lib, file) = makeLibrary()
        let t = song("abcdefghijk")
        #expect(lib.toggleLike(t) == true)
        #expect(lib.isLiked(t))
        #expect(lib.likedIDs.contains("abcdefghijk"))

        let reopened = Library(file: file)
        #expect(reopened.isLiked(t))

        #expect(lib.toggleLike(t) == false)
        #expect(lib.isLiked(t) == false)
    }

    @Test func dislikesAreKeptSeparately() {
        let (lib, _) = makeLibrary()
        let t = song("abcdefghijk")
        #expect(lib.toggleDislike(t) == true)
        #expect(lib.isDisliked(t))
        #expect(lib.isLiked(t) == false)
    }

    @Test func historyKeepsTheNewestFirstWithoutRepeats() {
        let (lib, _) = makeLibrary()
        lib.addHistory(song("aaaaaaaaaaa"))
        lib.addHistory(song("bbbbbbbbbbb"))
        lib.addHistory(song("aaaaaaaaaaa"))
        #expect(lib.history.map { $0.id } == ["aaaaaaaaaaa", "bbbbbbbbbbb"])
    }

    @Test func playlistsCanBeCreatedFilledRenamedAndDeleted() throws {
        let (lib, _) = makeLibrary()
        let p = lib.newPlaylist("Road trip", with: song("aaaaaaaaaaa"))
        #expect(lib.add(song("bbbbbbbbbbb"), to: p.id) == true)
        #expect(lib.add(song("bbbbbbbbbbb"), to: p.id) == false)        // already there
        #expect(try #require(lib.playlist(p.id)).tracks.count == 2)

        lib.rename(p.id, to: "  Night drive ")
        #expect(lib.playlist(p.id)?.name == "Night drive")
        lib.rename(p.id, to: "   ")                                     // an empty name is ignored
        #expect(lib.playlist(p.id)?.name == "Night drive")

        lib.remove(song("aaaaaaaaaaa"), from: p.id)
        #expect(lib.playlist(p.id)?.tracks.count == 1)
        lib.deletePlaylist(p.id)
        #expect(lib.playlist(p.id) == nil)
    }

    @Test func savedAlbumsAndArtistsToggle() {
        let (lib, _) = makeLibrary()
        let album = Coll(kind: "album", id: "MPREb_1", title: "Night Roads", subtitle: "Neon Harbor", thumbnail: nil)
        #expect(lib.toggleSaved(album) == true)
        #expect(lib.isSaved(album))
        #expect(lib.toggleSaved(album) == false)
    }

    @Test func playsAreRecorded() {
        let (lib, _) = makeLibrary()
        lib.recordPlay(song("abcdefghijk", "Echoes", artist: "Neon Harbor"), seconds: 120)
        #expect(lib.plays.count == 1)
        #expect(lib.plays[0].title == "Echoes")
        lib.clearPlays()
        #expect(lib.plays.isEmpty)
    }
}

@MainActor
@Suite("Backups from the earlier web version")
struct BackupTests {
    private func json(_ o: Any) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!
    }

    private func backupFile() -> Data {
        let track: [String: Any] = ["videoId": "abcdefghijk", "title": "Excuses", "artists": ["AP Dhillon"], "duration": "3:12"]
        let data: [String: String] = [
            "likes": json([track]),
            "history": json([track]),
            "library": json(["playlists": [["id": "L1", "name": "Road trip", "tracks": [track]]],
                             "saved": [["kind": "album", "id": "MPREb_1", "title": "Night Roads", "subtitle": "Neon Harbor"]]] as [String: Any]),
            "stats": json(["log": [[1_700_000_000, "abcdefghijk", 120]], "meta": ["abcdefghijk": ["Excuses", "AP Dhillon", "", ""]]] as [String: Any]),
            "genres": json([["id": "lo-fi", "name": "Lo-fi"]]),
        ]
        let file: [String: Any] = ["app": "yt-music", "version": 1, "data": data]
        return try! JSONSerialization.data(withJSONObject: file)
    }

    private func makeLibrary() -> Library {
        Library(file: FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString).json"))
    }

    @Test func aBackupIsMergedIn() throws {
        let lib = makeLibrary()
        let r = try lib.importWebBackup(backupFile())
        #expect(r.likes == 1)
        #expect(r.playlists == 1)
        #expect(r.plays == 1)
        #expect(lib.likes.first?.title == "Excuses")
        #expect(lib.history.count == 1)
        #expect(lib.playlists.first?.name == "Road trip")
        #expect(lib.saved.first?.kind == "album")
    }

    @Test func importingTwiceAddsNothingTheSecondTime() throws {
        let lib = makeLibrary()
        _ = try lib.importWebBackup(backupFile())
        let again = try lib.importWebBackup(backupFile())
        #expect(again.likes == 0)
        #expect(again.playlists == 0)
        #expect(again.plays == 0)
        #expect(lib.likes.count == 1)
        #expect(lib.playlists.count == 1)
    }

    @Test func aFileThatIsNotABackupIsRefused() {
        let lib = makeLibrary()
        #expect(throws: (any Error).self) { try lib.importWebBackup(Data("{\"hello\":1}".utf8)) }
        #expect(throws: (any Error).self) { try lib.importWebBackup(Data("not json".utf8)) }
    }

    @Test func anExportCanBeReadBack() throws {
        let lib = makeLibrary()
        _ = try lib.importWebBackup(backupFile())
        let out = lib.exportWebBackup()
        let root = try #require(try JSONSerialization.jsonObject(with: out) as? [String: Any])
        #expect(root["app"] as? String == "yt-music")
        let data = try #require(root["data"] as? [String: Any])
        let likes = try #require(try JSONSerialization.jsonObject(with: Data((data["likes"] as? String ?? "").utf8)) as? [[String: Any]])
        #expect(likes.first?["videoId"] as? String == "abcdefghijk")

        let other = makeLibrary()                                          // and the export imports cleanly
        let r = try other.importWebBackup(out)
        #expect(r.likes == 1)
        #expect(r.playlists == 1)
    }
}
