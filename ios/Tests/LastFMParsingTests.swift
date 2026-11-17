import Testing
import Foundation
@testable import YTMusic

@Suite("Last.fm pictures, albums and artists")
struct LastFMParsingTests {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    @Test func realPicturesAreKeptAndThePlaceholderIsDropped() {
        let json = #"""
        {"tracks":{"track":[
          {"name":"A","artist":{"name":"X"},"image":[{"#text":"http://img.example/a-64.png","size":"medium"},{"#text":"http://img.example/a-300.png","size":"extralarge"}]},
          {"name":"B","artist":{"name":"Y"},"image":[{"#text":"https://lastfm.freetls.fastly.net/i/u/300x300/2a96cbd8b46e442fc41c2b86b821562f.png","size":"extralarge"}]}
        ]}}
        """#
        let t = LastFM.parseTracks(data(json))
        #expect(t[0].image?.absoluteString == "https://img.example/a-300.png")       // the larger one, over https
        #expect(t[1].image == nil)                                                    // only the placeholder
    }

    @Test func albumsAreParsedFromTagAndArtistAnswers() {
        let tag = #"{"albums":{"album":[{"name":"Night Roads","artist":{"name":"Neon Harbor"},"image":[{"#text":"https://img.example/n.png","size":"extralarge"}]},{"name":"(null)","artist":{"name":"X"}}]}}"#
        let a = LastFM.parseAlbums(data(tag))
        #expect(a.count == 1)
        #expect(a[0].title == "Night Roads" && a[0].artist == "Neon Harbor")
        #expect(a[0].image != nil)

        let artist = #"{"topalbums":{"album":{"name":"Singles","artist":{"name":"Lila Moreno"}}}}"#
        #expect(LastFM.parseAlbums(data(artist)).map { $0.title } == ["Singles"])
    }

    @Test func artistsAreParsedFromChartSimilarAndTopAnswers() {
        #expect(LastFM.parseArtists(data(#"{"artists":{"artist":[{"name":"Neon Harbor"},{"name":"Lila Moreno"}]}}"#)).map { $0.name } == ["Neon Harbor", "Lila Moreno"])
        #expect(LastFM.parseArtists(data(#"{"similarartists":{"artist":[{"name":"Sunday Static"}]}}"#)).map { $0.name } == ["Sunday Static"])
        #expect(LastFM.parseArtists(data(#"{"topartists":{"artist":{"name":"Arjun Rao"}}}"#)).map { $0.name } == ["Arjun Rao"])
        #expect(LastFM.parseArtists(data("{}")).isEmpty)
    }

    @Test func anAlbumCarriesItsCoverToEachSong() throws {
        let json = #"""
        {"album":{"name":"Night Roads","artist":"Neon Harbor","image":[{"#text":"https://img.example/c.png","size":"extralarge"}],
          "tracks":{"track":[{"name":"Midnight Drive","artist":{"name":"Neon Harbor"}},{"name":"Echoes","artist":{"name":"Neon Harbor"}}]}}}
        """#
        let info = try #require(LastFM.parseAlbumInfo(data(json)))
        #expect(info.album.title == "Night Roads")
        #expect(info.album.artist == "Neon Harbor")
        #expect(info.tracks.map { $0.title } == ["Midnight Drive", "Echoes"])
        #expect(info.tracks.allSatisfy { $0.image?.absoluteString == "https://img.example/c.png" })
    }

    @Test func anAlbumWithOneSongAndNoArtistOnTheSongStillParses() throws {
        let json = #"{"album":{"name":"Single","artist":"Lila Moreno","tracks":{"track":{"name":"Paper Planes"}}}}"#
        let info = try #require(LastFM.parseAlbumInfo(data(json)))
        #expect(info.tracks == [LFMTrack(title: "Paper Planes", artist: "Lila Moreno")])
    }

    @Test func anAnswerWithoutAnAlbumGivesNothing() {
        #expect(LastFM.parseAlbumInfo(data("{}")) == nil)
    }

    @Test func theCoverOfASongsAlbumIsRead() {
        let json = #"{"track":{"name":"X","album":{"title":"A","image":[{"#text":"https://img.example/t.png","size":"large"}]}}}"#
        #expect(LastFM.parseTrackArt(data(json))?.absoluteString == "https://img.example/t.png")
        #expect(LastFM.parseTrackArt(data(#"{"track":{"name":"X"}}"#)) == nil)
    }
}
