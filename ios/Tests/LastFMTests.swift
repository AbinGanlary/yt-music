import Testing
import Foundation
@testable import YTMusic

@Suite("Last.fm")
struct LastFMTests {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    @Test func theRequestAddressIsBuiltAndEncoded() throws {
        let u = try #require(LastFM.url("track.getSimilar", ["artist": "Mira & the Tides", "track": "C++ Dreams"], key: "abc123"))
        let text = u.absoluteString
        #expect(text.hasPrefix("https://ws.audioscrobbler.com/2.0/?method=track.getSimilar&api_key=abc123&format=json"))
        #expect(text.contains("artist=Mira%20%26%20the%20Tides"))
        #expect(text.contains("track=C%2B%2B%20Dreams"))          // "+" must not read as a space
    }

    @Test func aChartAnswerIsParsed() {
        let json = #"{"tracks":{"track":[{"name":"Midnight Drive","artist":{"name":"Neon Harbor"}},{"name":"Echoes","artist":{"name":"Lila Moreno"}}]}}"#
        #expect(LastFM.parseTracks(data(json)) == [LFMTrack(title: "Midnight Drive", artist: "Neon Harbor"), LFMTrack(title: "Echoes", artist: "Lila Moreno")])
    }

    @Test func aSimilarTracksAnswerIsParsedEvenWithOneSong() {
        let one = #"{"similartracks":{"track":{"name":"Slow Burn","artist":{"name":"The Quiet Hours"},"match":0.9}}}"#
        #expect(LastFM.parseTracks(data(one)) == [LFMTrack(title: "Slow Burn", artist: "The Quiet Hours")])
    }

    @Test func duplicatesAndBrokenRowsAreSkipped() {
        let json = #"{"tracks":{"track":[{"name":"Echoes","artist":{"name":"Lila Moreno"}},{"name":"echoes","artist":{"name":"LILA MORENO"}},{"artist":{"name":"No Title"}},{"name":"No Artist"}]}}"#
        #expect(LastFM.parseTracks(data(json)).count == 1)
    }

    @Test func anEmptyOrUnknownAnswerGivesNothing() {
        #expect(LastFM.parseTracks(data("{}")).isEmpty)
        #expect(LastFM.parseTracks(data("not json")).isEmpty)
    }

    @Test func errorsAreRecognised() {
        #expect(LastFM.errorMessage(data(#"{"error":10,"message":"Invalid API key - You must be granted a valid key by last.fm"}"#))?.hasPrefix("Invalid API key") == true)
        #expect(LastFM.errorMessage(data(#"{"tracks":{}}"#)) == nil)
    }

    @Test func tagsAreParsed() {
        let json = #"{"tags":{"tag":[{"name":"rock"},{"name":"electronic"},{"name":"indie"}]}}"#
        #expect(LastFM.parseTags(data(json)) == ["rock", "electronic", "indie"])
    }

    @Test func countryCodesBecomeEnglishNames() {
        #expect(LastFM.countryName("IN") == "India")
        #expect(LastFM.countryName("gb") == "United Kingdom")
    }
}

@Suite("Matching Last.fm songs to YouTube Music")
struct SongMatchTests {
    private func song(_ id: String, _ title: String, _ artist: String) -> Track { Track(id: id, title: title, artist: artist, seconds: 200) }

    @Test func namesAreNormalised() {
        #expect(SongMatch.normalize("Don't Stop (Remastered 2011)") == "don t stop")
        #expect(SongMatch.normalize("Echoes [Live]") == "echoes")
        #expect(SongMatch.normalize("  Paper   Planes! ") == "paper planes")
    }

    @Test func theExactSongBeatsACover() {
        let results = [song("aaaaaaaaaaa", "Paper Planes (Cover)", "Some Band"), song("bbbbbbbbbbb", "Paper Planes", "Lila Moreno"), song("ccccccccccc", "Paper Planes - Live", "Lila Moreno")]
        #expect(SongMatch.pick(results, title: "Paper Planes", artist: "Lila Moreno")?.id == "bbbbbbbbbbb")
    }

    @Test func theFirstResultWinsATie() {
        let results = [song("aaaaaaaaaaa", "Echoes", "Neon Harbor"), song("bbbbbbbbbbb", "Echoes", "Neon Harbor")]
        #expect(SongMatch.pick(results, title: "Echoes", artist: "Neon Harbor")?.id == "aaaaaaaaaaa")
    }

    @Test func aPartialArtistNameStillMatches() {
        let results = [song("aaaaaaaaaaa", "Something Else", "Other"), song("bbbbbbbbbbb", "Golden Hour", "Sunday Static, Guest")]
        #expect(SongMatch.pick(results, title: "Golden Hour", artist: "Sunday Static")?.id == "bbbbbbbbbbb")
    }

    @Test func noResultsGivesNothing() {
        #expect(SongMatch.pick([], title: "Echoes", artist: "Neon Harbor") == nil)
    }
}
