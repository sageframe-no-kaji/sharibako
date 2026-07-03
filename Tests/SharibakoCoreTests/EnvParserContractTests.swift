import Foundation
import Testing

@testable import SharibakoCore

/// ho-04.10 parser contract specs: per-line CRLF preservation, the `$`
/// canonicalization fallback chain, warned swallows, and intended-key
/// extraction.
///
/// Split from `EnvParserTests` to keep each test struct under the
/// type-body-length ceiling.
@Suite("Env Parser Contract (ho-04.10)")
struct EnvParserContractTests {
    private static let dummyURL = URL(fileURLWithPath: "/tmp/.env")

    private func parse(_ text: String) -> ParseResult {
        parseEnvString(text, sourceFile: Self.dummyURL)
    }

    // MARK: - CRLF round-trips (D1)

    @Test("CRLF file round-trips byte-for-byte through parse and render")
    func crlfRoundTrip() {
        let source = "# top\r\nA=1\r\n\r\nB=\"two\"\r\n"
        let result = parse(source)
        let rendered = renderEnvLines(result.lines, withTrailingNewline: result.hadTrailingNewline)
        #expect(rendered == source)
    }

    @Test("mixed-ending file round-trips byte-for-byte — each line keeps its own terminator")
    func mixedEndingsRoundTrip() {
        let source = "A=1\r\nB=2\nC=3\r\nnot a valid line\n"
        let result = parse(source)
        let rendered = renderEnvLines(result.lines, withTrailingNewline: result.hadTrailingNewline)
        #expect(rendered == source)
    }

    @Test("CRLF file without trailing newline round-trips")
    func crlfNoTrailingNewlineRoundTrip() {
        let source = "A=1\r\nB=2"
        let result = parse(source)
        #expect(result.hadTrailingNewline == false)
        let rendered = renderEnvLines(result.lines, withTrailingNewline: result.hadTrailingNewline)
        #expect(rendered == source)
    }

    @Test(
        "dominant line ending",
        arguments: [
            ("A=1\nB=2\n", false),
            ("A=1\r\nB=2\r\n", true),
            ("A=1\r\nB=2", true),  // final line has no terminator; tie breaks CRLF
            ("A=1\r\nB=2\nC=3\n", false),
            ("", false),
        ])
    func dominantLineEnding(source: String, expectCRLF: Bool) {
        let result = parse(source)
        #expect(dominantLineEndingIsCRLF(result.lines) == expectCRLF)
    }

    // MARK: - $ canonicalization fallbacks (D2)

    @Test("canonicalize $ with a single quote falls back to double quotes with \\$")
    func canonicalizeDollarWithSingleQuote() {
        #expect(canonicalizeEnvLine(key: "K", value: "it's $5") == "K=\"it's \\$5\"")
    }

    @Test("canonicalize $ with a newline falls back to double quotes with \\$")
    func canonicalizeDollarWithNewline() {
        #expect(canonicalizeEnvLine(key: "K", value: "$a\nb") == "K=\"\\$a\\nb\"")
    }

    @Test("canonical single-quoted and \\$ forms both parse back to the original value")
    func canonicalizeDollarRoundTrip() {
        for value in ["$FOO", "pa$$word", "it's $5", "$a\nb"] {
            let line = canonicalizeEnvLine(key: "K", value: value)
            let result = parse(line)
            #expect(result.lines == [.keyValue(key: "K", value: value, rawText: line)])
            #expect(result.warnings.isEmpty)
        }
    }

    // MARK: - Warned swallows (D5)

    @Test("unknown escape in double-quoted value warns; backslash still dropped")
    func unknownEscapeWarns() {
        let raw = "K=\"a\\xb\""
        let result = parse(raw)
        #expect(result.lines == [.keyValue(key: "K", value: "axb", rawText: raw)])
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].reason.contains("unknown escape"))
    }

    @Test("\\$ in double-quoted value is a known escape — decodes to $, no warning")
    func dollarEscapeKnown() {
        let raw = "K=\"\\$FOO\""
        let result = parse(raw)
        #expect(result.lines == [.keyValue(key: "K", value: "$FOO", rawText: raw)])
        #expect(result.warnings.isEmpty)
    }

    @Test("text after a closing double quote warns; value unchanged")
    func postQuoteJunkWarns() {
        let raw = "K=\"abc\"junk"
        let result = parse(raw)
        #expect(result.lines == [.keyValue(key: "K", value: "abc", rawText: raw)])
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].reason.contains("after the closing quote"))
    }

    @Test("text after a closing single quote warns; value unchanged")
    func postSingleQuoteJunkWarns() {
        let raw = "K='abc' oops"
        let result = parse(raw)
        #expect(result.lines == [.keyValue(key: "K", value: "abc", rawText: raw)])
        #expect(result.warnings.count == 1)
    }

    @Test("trailing comment after a closing quote stays silent")
    func postQuoteTrailingCommentSilent() {
        for raw in ["K=\"abc\" # note", "K='abc' # note", "K=\"abc\"  "] {
            let result = parse(raw)
            #expect(result.lines == [.keyValue(key: "K", value: "abc", rawText: raw)])
            #expect(result.warnings.isEmpty)
        }
    }

    // MARK: - Intended key (D4 support)

    @Test(
        "envLineIntendedKey extracts the key a line intends, valid or not",
        arguments: [
            ("KEY=\"unterminated", "KEY"),
            ("  export KEY='oops", "KEY"),
            ("KEY=$BARE", "KEY"),
            ("KEY=ok", "KEY"),
        ])
    func intendedKey(text: String, expected: String) {
        #expect(envLineIntendedKey(text) == expected)
    }

    @Test(
        "envLineIntendedKey returns nil when no key prefix exists",
        arguments: ["no equals sign", "1KEY=x", "# comment", "", "=value"])
    func intendedKeyNil(text: String) {
        #expect(envLineIntendedKey(text) == nil)
    }
}
