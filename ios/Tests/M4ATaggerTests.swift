import Testing
import Foundation
@testable import YTMusic

@Suite("Tagging exported .m4a files")
struct M4ATaggerTests {
    private func be32(_ n: Int) -> Data { Data([UInt8((n >> 24) & 255), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)]) }
    private func box(_ type: String, _ body: Data) -> Data { be32(body.count + 8) + Data(type.utf8) + body }

    private let audio = Data("AUDIO-DATA-0123456789".utf8)

    /// A tiny mp4: ftyp, a moov with one chunk offset, and an mdat. `moovFirst` decides which comes first.
    private func makeFile(moovFirst: Bool, withOldTags: Bool = false) -> Data {
        let ftyp = box("ftyp", Data("M4A ".utf8) + be32(0) + Data("M4A mp42isom".utf8))
        let mdat = box("mdat", audio)
        func moov(chunkOffset: Int) -> Data {
            let stco = box("stco", be32(0) + be32(1) + be32(chunkOffset))
            let trak = box("trak", box("mdia", box("minf", box("stbl", stco))))
            var body = box("mvhd", Data(count: 100)) + trak
            if withOldTags { body += box("udta", box("free", Data(count: 20))) }
            return box("moov", body)
        }
        if moovFirst {
            let size = moov(chunkOffset: 0).count
            return ftyp + moov(chunkOffset: ftyp.count + size + 8) + mdat       // +8 for the mdat header
        }
        return ftyp + mdat + moov(chunkOffset: ftyp.count + 8)
    }

    /// Where the first chunk offset in the file points, and the ten bytes found there.
    private func firstChunk(_ file: Data) -> String? {
        guard let r = file.range(of: Data("stco".utf8)) else { return nil }
        let at = r.upperBound + 8                                   // version/flags + entry count
        let offset = (Int(file[at]) << 24) | (Int(file[at + 1]) << 16) | (Int(file[at + 2]) << 8) | Int(file[at + 3])
        guard offset + 10 <= file.count else { return nil }
        return String(decoding: file[offset..<offset + 10], as: UTF8.self)
    }

    private let cover = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4, 5, 6])

    @Test(arguments: [true, false])
    func tagsAreWrittenAndTheAudioStaysReachable(moovFirst: Bool) throws {
        let source = makeFile(moovFirst: moovFirst)
        #expect(firstChunk(source) == "AUDIO-DATA")                    // the test file itself is right

        let tagged = M4ATagger.tag(source, title: "Excuses", artist: "AP Dhillon", album: "The Brownprint", cover: cover)

        #expect(tagged.count > source.count)
        for text in ["Excuses", "AP Dhillon", "The Brownprint"] {
            #expect(tagged.range(of: Data(text.utf8)) != nil, "missing \(text)")
        }
        #expect(tagged.range(of: Data("covr".utf8)) != nil)
        #expect(tagged.range(of: cover) != nil)
        #expect(firstChunk(tagged) == "AUDIO-DATA")                    // the chunk offset moved with the bigger moov box
        #expect(tagged.range(of: audio) != nil)
    }

    @Test func oldTagsAreReplacedNotDuplicated() {
        let tagged = M4ATagger.tag(makeFile(moovFirst: true, withOldTags: true), title: "T", artist: "A", album: nil, cover: nil)
        let count = tagged.ranges(of: Data("udta".utf8)).count
        #expect(count == 1)
        #expect(tagged.range(of: Data("free".utf8)) == nil)
    }

    @Test func aFileThatIsNotAnMP4IsReturnedUntouched() {
        let junk = Data("this is not an mp4 file at all".utf8)
        #expect(M4ATagger.tag(junk, title: "T", artist: "A", album: "B", cover: nil) == junk)
    }

    @Test func noTagsMeansNoChange() {
        let source = makeFile(moovFirst: true)
        #expect(M4ATagger.tag(source, title: "", artist: "", album: nil, cover: nil) == source)
    }
}

private extension Data {
    /// Every place `needle` occurs.
    func ranges(of needle: Data) -> [Range<Data.Index>] {
        var out: [Range<Data.Index>] = []
        var from = startIndex
        while let r = range(of: needle, in: from..<endIndex) {
            out.append(r)
            from = r.upperBound
        }
        return out
    }
}
