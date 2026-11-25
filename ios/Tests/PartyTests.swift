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
}
