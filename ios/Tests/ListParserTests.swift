import Testing
@testable import YTMusic

@Suite("Search a list: reading pasted text")
struct ListParserTests {
    @Test func plainLinesBecomeQueries() {
        let text = """
        1. Excuses - AP Dhillon
        2) Blinding Lights – The Weeknd

        Paper Planes   Lila Moreno
        """
        #expect(ListParser.parse(text) == ["Excuses AP Dhillon", "Blinding Lights The Weeknd", "Paper Planes Lila Moreno"])
    }

    @Test func duplicatesAreRemoved() {
        #expect(ListParser.parse("Echoes - Neon Harbor\nEchoes - Neon Harbor\n").count == 1)
    }

    @Test func emptyTextGivesNothing() {
        #expect(ListParser.parse("").isEmpty)
        #expect(ListParser.parse("   \n \n").isEmpty)
    }

    @Test func aCSVUsesTheTitleAndFirstArtist() {
        let csv = """
        Track Name,Artist Name(s),Album
        Midnight Drive,Neon Harbor;Guest,Night Roads
        "Hello, World",Lila Moreno,Singles
        """
        #expect(ListParser.parse(csv) == ["Midnight Drive Neon Harbor", "Hello, World Lila Moreno"])
    }

    @Test func quotedCellsKeepTheirCommas() {
        #expect(ListParser.cells(#"a,"b, c",d"#) == ["a", "b, c", "d"])
        #expect(ListParser.cells(#""say ""hi""",x"#) == [#"say "hi""#, "x"])
    }
}
