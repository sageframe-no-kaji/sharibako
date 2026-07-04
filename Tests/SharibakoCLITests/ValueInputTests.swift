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

    @Test("read throws valueInputRequired when neither flag is set and no terminal is available")
    func readNeitherThrowsRequired() {
        // securePrompt nil = non-TTY stdin; pinned explicitly so the test
        // doesn't depend on whether the test runner itself has a terminal.
        var input = ValueInput(value: nil, fromStdin: false)
        input.securePrompt = nil
        #expect(throws: CLIError.valueInputRequired) {
            _ = try input.read()
        }
    }

    // MARK: - Secure prompt routing (ho-04.11)

    @Test("read runs the secure prompt when neither flag is set and a terminal is available")
    func readNeitherRunsSecurePrompt() throws {
        var input = ValueInput(value: nil, fromStdin: false)
        input.securePrompt = { "prompted-secret" }
        #expect(try input.read() == "prompted-secret")
    }

    @Test("--value bypasses the secure prompt even when one is available")
    func readValueBypassesPrompt() throws {
        var input = ValueInput(value: "flag-value", fromStdin: false)
        input.securePrompt = {
            Issue.record("secure prompt must not run when --value is supplied")
            return "wrong"
        }
        #expect(try input.read() == "flag-value")
    }

    @Test("--from-stdin bypasses the secure prompt even when one is available")
    func readStdinBypassesPrompt() throws {
        var input = ValueInput(value: nil, fromStdin: true) { Data("piped\n".utf8) }
        input.securePrompt = {
            Issue.record("secure prompt must not run when --from-stdin is supplied")
            return "wrong"
        }
        #expect(try input.read() == "piped")
    }
}
