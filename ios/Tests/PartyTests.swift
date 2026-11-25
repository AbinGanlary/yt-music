import Testing
@testable import YTMusic

@Suite("Party mode")
struct PartyTests {
    @Test func theSameSongFromAFilmCountsOnce() {
        #expect(PartyView.titleKey("Kala Chashma (From “Baar Baar Dekho”)") == PartyView.titleKey("Kala Chashma"))
        #expect(PartyView.titleKey("Tauba Tauba") != PartyView.titleKey("Tauba Tauba Remix Mashup"))
    }

    @Test func everyVibeHasASearch() {
        #expect(!partyVibes.isEmpty)
        #expect(partyVibes.allSatisfy { !$0.query.isEmpty && !$0.symbol.isEmpty })
        #expect(Set(partyVibes.map { $0.name }).count == partyVibes.count)
    }

    @Test func findsTheTempoAndBeatsOfAClickTrack() throws {
        let rate = 11025.0, bpm = 124.0, first = 0.3
        let per = 60 / bpm
        var x = [Float](repeating: 0, count: Int(rate * 40))
        var t = first
        while t < 39.5 {
            let i = Int(t * rate)
            for j in 0..<400 { x[i + j] += (sin(Float(j) * 0.05) + 0.5 * sin(Float(j) * 0.4)) * exp(-Float(j) / 90) }
            t += per
        }
        let r = try #require(BeatTracker.analyze(x, rate: rate))
        #expect(abs(r.bpm - bpm) < 0.3)
        var off = (r.phase - first).truncatingRemainder(dividingBy: per)
        if off < 0 { off += per }
        if off > per / 2 { off -= per }
        #expect(abs(off) < 0.03)
        #expect(abs(r.drift) < 0.02)
    }

    @Test func snapsToTheNearestBeat() {
        let g = BeatGrid(bpm: 120, anchor: 0.25, sure: true)
        #expect(abs(g.snap(10.1) - 10.25) < 1e-9)
        #expect(abs(g.phase(10.5) - 0.5) < 1e-9)
    }
}
