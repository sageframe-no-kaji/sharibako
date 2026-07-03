import Foundation
import Testing

@testable import SharibakoCLI

@Suite("ValueInput")
struct ValueInputTests {
    @Test("read returns the --value literal untouched")
    func readLiteralValue() throws {
        let input = ValueInput(value: "sk-live-abc", fromStdin: false)
        #expect(try input.read() == "sk-live-abc")
    }

    @Test("read strips a single trailing newline from stdin")
    func readStdinStripsTrailingNewline() throws {
        let input = ValueInput(value: nil, fromStdin: true) { Data("secret-value\n".utf8) }
        #expect(try input.read() == "secret-value")
    }

    @Test("read keeps stdin verbatim when there is no trailing newline")
    func readStdinNoTrailingNewline() throws {
        let input = ValueInput(value: nil, fromStdin: true) { Data("secret-value".utf8) }
        #expect(try input.read() == "secret-value")
    }

    @Test("read strips only the last newline, preserving embedded ones")
    func readStdinPreservesEmbeddedNewlines() throws {
        let input = ValueInput(value: nil, fromStdin: true) { Data("line1\nline2\n".utf8) }
        #expect(try input.read() == "line1\nline2")
    }

    @Test("read maps non-UTF-8 stdin bytes to an empty string")
    func readStdinNonUTF8() throws {
        let input = ValueInput(value: nil, fromStdin: true) { Data([0xFF, 0xFE, 0xFD]) }
        #expect(try input.read().isEmpty)
    }

    @Test("read throws valueInputConflict when both --value and --from-stdin are set")
    func readBothThrowsConflict() {
        let input = ValueInput(value: "x", fromStdin: true)
        #expect(throws: CLIError.valueInputConflict) {
            _ = try input.read()
        }
    }

    @Test("read throws valueInputRequired when neither --value nor --from-stdin is set")
    func readNeitherThrowsRequired() {
        let input = ValueInput(value: nil, fromStdin: false)
        #expect(throws: CLIError.valueInputRequired) {
            _ = try input.read()
        }
    }
}
