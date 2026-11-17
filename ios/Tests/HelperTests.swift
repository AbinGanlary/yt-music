import Testing
import Foundation
@testable import YTMusic

@Suite("Small helpers")
struct HelperTests {
    @Test func coverAddressesAreResized() {
        let u = sizedURL("https://lh3.googleusercontent.com/abc=w60-h60-l90-rj", 400)
        #expect(u?.absoluteString == "https://lh3.googleusercontent.com/abc=w400-h400-l90-rj")
    }

    @Test func otherAddressesAreLeftAlone() {
        #expect(sizedURL("https://example.com/a.jpg")?.absoluteString == "https://example.com/a.jpg")
        #expect(sizedURL(nil) == nil)
    }

    @Test(arguments: [(0, "0 songs"), (1, "1 song"), (2, "2 songs"), (42, "42 songs")])
    func songCountsPluralize(count: Int, text: String) {
        #expect(songsLabel(count) == text)
    }

    @Test func clockFormatsMinutesAndSeconds() {
        #expect(clock(0) == "0:00")
        #expect(clock(9) == "0:09")
        #expect(clock(90) == "1:30")
        #expect(clock(3_725) == "62:05")
        #expect(clock(-5) == "0:00")
    }

    @Test func tasteRoundTrips() {
        let stored = Taste.store([(id: "UC1", name: "Neon Harbor"), (id: "UC2", name: "Lila Moreno")])
        let back = Taste.artists(stored)
        #expect(back.count == 2)
        #expect(back[0].id == "UC1" && back[0].name == "Neon Harbor")
        #expect(Taste.langs("Hindi,English") == ["Hindi", "English"])
        #expect(Taste.langs("").isEmpty)
    }
}

@Suite("Songs from the engine")
struct TrackTests {
    private func raw(_ json: String) throws -> RawTrack {
        try JSONDecoder().decode(RawTrack.self, from: Data(json.utf8))
    }

    @Test func aSongIsBuiltFromEngineJSON() throws {
        let r = try raw(#"{"videoId":"abcdefghijk","title":"Midnight Drive","artists":["Neon Harbor","Guest"],"duration":"3:45","thumbnail":"https://lh3.googleusercontent.com/x=w60-h60"}"#)
        let t = try #require(Track(r))
        #expect(t.id == "abcdefghijk")
        #expect(t.artist == "Neon Harbor, Guest")
        #expect(t.seconds == 225)
        #expect(t.thumbnail?.absoluteString.contains("w400-h400") == true)
    }

    @Test(arguments: [("0:59", 59), ("1:02:03", 3_723), ("12", 12)])
    func durationsAreParsed(text: String, seconds: Int) throws {
        let r = try raw(#"{"videoId":"abcdefghijk","title":"T","duration":"\#(text)"}"#)
        #expect(Track(r)?.seconds == seconds)
    }

    @Test func aMissingDurationGetsADefault() throws {
        let r = try raw(#"{"videoId":"abcdefghijk","title":"T"}"#)
        #expect(Track(r)?.seconds == 200)
    }

    @Test func aSongWithoutATitleIsDropped() throws {
        #expect(Track(try raw(#"{"videoId":"abcdefghijk"}"#)) == nil)
        #expect(Track(try raw(#"{"videoId":"abcdefghijk","title":""}"#)) == nil)
    }
}
