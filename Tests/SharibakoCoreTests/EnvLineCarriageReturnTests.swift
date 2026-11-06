import Foundation
import Testing

@testable import SharibakoCore

/// CRLF terminator round-tripping on `EnvLine`.
///
/// `appendingCarriageReturn()`/`removingCarriageReturn()` are the pair that lets
/// a CRLF `.env` survive a Materializer write byte-for-byte (ho-04.10): the
/// parser strips `\r` before reading key/value content and the renderer puts it
/// back. Both directions are exercised over every case so a new `EnvLine` case
/// cannot silently skip the terminator.
@Suite("EnvLine carriage returns")
struct EnvLineCarriageReturnTests {
    @Test("appendingCarriageReturn re-attaches the terminator to every case")
    func appendingCoversEveryCase() {
        #expect(EnvLine.blank(text: "").appendingCarriageReturn() == .blank(text: "\r"))
        #expect(
            EnvLine.comment(text: "# note").appendingCarriageReturn() == .comment(text: "# note\r"))
        #expect(
            EnvLine.malformed(text: "NOSEP", reason: "no separator").appendingCarriageReturn()
                == .malformed(text: "NOSEP\r", reason: "no separator"))
        #expect(
            EnvLine.keyValue(key: "K", value: "v", rawText: "K=v").appendingCarriageReturn()
                == .keyValue(key: "K", value: "v", rawText: "K=v\r"))
    }

    @Test("removingCarriageReturn strips the terminator from every case")
    func removingCoversEveryCase() {
        #expect(EnvLine.blank(text: "\r").removingCarriageReturn() == .blank(text: ""))
        #expect(
            EnvLine.comment(text: "# note\r").removingCarriageReturn() == .comment(text: "# note"))
        #expect(
            EnvLine.malformed(text: "NOSEP\r", reason: "no separator").removingCarriageReturn()
                == .malformed(text: "NOSEP", reason: "no separator"))
        #expect(
            EnvLine.keyValue(key: "K", value: "v", rawText: "K=v\r").removingCarriageReturn()
                == .keyValue(key: "K", value: "v", rawText: "K=v"))
    }

    @Test("removingCarriageReturn is a no-op on a line that has no terminator")
    func removingIsNoOpWithoutTerminator() {
        let plain = EnvLine.keyValue(key: "K", value: "v", rawText: "K=v")
        #expect(plain.removingCarriageReturn() == plain)
        #expect(EnvLine.blank(text: "").removingCarriageReturn() == .blank(text: ""))
    }

    @Test("endsWithCR reads the stored text of every case")
    func endsWithCRAcrossCases() {
        #expect(EnvLine.blank(text: "\r").endsWithCR)
        #expect(EnvLine.comment(text: "# c\r").endsWithCR)
        #expect(EnvLine.malformed(text: "x\r", reason: "r").endsWithCR)
        #expect(EnvLine.keyValue(key: "K", value: "v", rawText: "K=v\r").endsWithCR)
        #expect(EnvLine.keyValue(key: "K", value: "v", rawText: "K=v").endsWithCR == false)
    }

    @Test("append then remove round-trips every case back to itself")
    func roundTripIsIdentity() {
        let lines: [EnvLine] = [
            .blank(text: ""),
            .comment(text: "# note"),
            .malformed(text: "NOSEP", reason: "no separator"),
            .keyValue(key: "K", value: "v", rawText: "K=v"),
        ]
        for line in lines {
            #expect(line.appendingCarriageReturn().removingCarriageReturn() == line)
        }
    }
}
