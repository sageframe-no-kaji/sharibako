import Foundation
import Testing

@testable import SharibakoCore

/// Unit tests for `EnvParser`.
///
/// The parser is internal to `SharibakoCore` — exposed to tests via `@testable import`.
/// Each case exercises one behavior in the AT-01 spec §7 checklist.
@Suite("Env Parser")
struct EnvParserTests {
    private static let dummyURL = URL(fileURLWithPath: "/tmp/.env")

    private func parse(_ text: String) -> ParseResult {
        parseEnvString(text, sourceFile: Self.dummyURL)
    }

    // MARK: - Empty and whitespace inputs

    @Test("empty string produces zero lines and no warnings")
    func emptyFile() {
        let result = parse("")
        #expect(result.lines.isEmpty)
        #expect(result.warnings.isEmpty)
        #expect(result.hadTrailingNewline == false)
    }

    @Test("only blank lines: every line is .blank, trailing newline preserved")
    func onlyBlankLines() {
        let result = parse("\n\n   \n\t\n")
        #expect(result.hadTrailingNewline == true)
        #expect(result.lines.count == 4)
        for line in result.lines {
            switch line {
            case .blank: break
            default: Issue.record("expected .blank, got \(line)")
            }
        }
    }

    @Test("only comments: every line is .comment, whole-line text preserved")
    func onlyComments() {
        let result = parse("# top-level comment\n  # indented comment\n")
        #expect(result.lines.count == 2)
        #expect(result.lines[0] == .comment(text: "# top-level comment"))
        #expect(result.lines[1] == .comment(text: "  # indented comment"))
        #expect(result.warnings.isEmpty)
    }

    // MARK: - Simple key/value forms

    @Test("bare KEY=value parses as .keyValue with matching rawText")
    func bareKeyValue() {
        let result = parse("FOO=bar")
        #expect(result.lines == [.keyValue(key: "FOO", value: "bar", rawText: "FOO=bar")])
        #expect(result.hadTrailingNewline == false)
    }

    @Test("bare value with spaces is preserved (no trim)")
    func bareValueWithSpaces() {
        let result = parse("MSG=hello world friend")
        #expect(
            result.lines == [
                .keyValue(key: "MSG", value: "hello world friend", rawText: "MSG=hello world friend")
            ])
    }

    @Test("bare value preserves leading and trailing whitespace verbatim")
    func bareValueLeadingTrailingSpaces() {
        let raw = "PAD=  value  "
        let result = parse(raw)
        #expect(result.lines == [.keyValue(key: "PAD", value: "  value  ", rawText: raw)])
    }

    @Test("empty bare value parses as .keyValue with value \"\"")
    func emptyBareValue() {
        let result = parse("EMPTY=")
        #expect(result.lines == [.keyValue(key: "EMPTY", value: "", rawText: "EMPTY=")])
    }

    // MARK: - Quoted values

    @Test("double-quoted value strips outer quotes")
    func doubleQuoted() {
        let raw = "MSG=\"hello world\""
        let result = parse(raw)
        #expect(
            result.lines == [
                .keyValue(key: "MSG", value: "hello world", rawText: raw)
            ])
    }

    @Test("double-quoted value with escaped quotes")
    func doubleQuotedWithEscapes() {
        let raw = "MSG=\"a \\\"quoted\\\" word\""
        let result = parse(raw)
        #expect(
            result.lines == [
                .keyValue(key: "MSG", value: "a \"quoted\" word", rawText: raw)
            ])
    }

    @Test("double-quoted value with \\n escape decodes to newline")
    func doubleQuotedWithNewlineEscape() {
        let raw = "MSG=\"line1\\nline2\""
        let result = parse(raw)
        #expect(
            result.lines == [
                .keyValue(key: "MSG", value: "line1\nline2", rawText: raw)
            ])
    }

    @Test("single-quoted value is literal (no interpolation, no escapes)")
    func singleQuotedLiteral() {
        let raw = "LITERAL='foo $bar \\n'"
        let result = parse(raw)
        #expect(
            result.lines == [
                .keyValue(key: "LITERAL", value: "foo $bar \\n", rawText: raw)
            ])
    }

    // MARK: - Export prefix

    @Test("export prefix is consumed; key/value parsed; rawText preserves export")
    func exportPrefix() {
        let raw = "export FOO=bar"
        let result = parse(raw)
        #expect(result.lines == [.keyValue(key: "FOO", value: "bar", rawText: raw)])
    }

    @Test("export with multiple spaces before key")
    func exportPrefixMultipleSpaces() {
        let raw = "export    FOO=bar"
        let result = parse(raw)
        #expect(result.lines == [.keyValue(key: "FOO", value: "bar", rawText: raw)])
    }

    // MARK: - Encoding quirks

    @Test("UTF-8 BOM at start is stripped and a warning emitted")
    func utf8BOMStripped() {
        let raw = "\u{FEFF}FOO=bar\n"
        let result = parse(raw)
        #expect(result.lines.count == 1)
        #expect(result.lines[0] == .keyValue(key: "FOO", value: "bar", rawText: "FOO=bar"))
        #expect(result.hadTrailingNewline == true)
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].lineNumber == 1)
        #expect(result.warnings[0].reason.contains("BOM"))
    }

    @Test("CRLF endings parse cleanly with no warning")
    func crlfLineEndings() {
        let raw = "A=1\r\nB=2\r\n"
        let result = parse(raw)
        #expect(result.lines.count == 2)
        #expect(result.lines[0] == .keyValue(key: "A", value: "1", rawText: "A=1"))
        #expect(result.lines[1] == .keyValue(key: "B", value: "2", rawText: "B=2"))
        #expect(result.warnings.isEmpty)
        #expect(result.hadTrailingNewline == true)
    }

    // MARK: - Malformed rejections

    @Test("key starting with a digit is malformed")
    func keyStartsWithDigit() {
        let raw = "1KEY=value"
        let result = parse(raw)
        #expect(result.lines.count == 1)
        guard case .malformed(let text, _) = result.lines[0] else {
            Issue.record("expected .malformed")
            return
        }
        #expect(text == raw)
        #expect(result.warnings.count == 1)
    }

    @Test("unterminated double quote is malformed")
    func unterminatedDoubleQuote() {
        let raw = "K=\"oops"
        let result = parse(raw)
        #expect(result.lines.count == 1)
        guard case .malformed = result.lines[0] else {
            Issue.record("expected .malformed")
            return
        }
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].reason.contains("unterminated"))
    }

    @Test("unterminated single quote is malformed")
    func unterminatedSingleQuote() {
        let raw = "K='no close"
        let result = parse(raw)
        guard case .malformed = result.lines[0] else {
            Issue.record("expected .malformed")
            return
        }
        #expect(result.warnings.count == 1)
    }

    @Test("multi-line double-quoted value (unclosed on same line) is malformed")
    func multiLineDoubleQuotedValue() {
        // First line opens quote and never closes on same line → malformed.
        // Second line 'line2' fails key parse rules too (has no `=`).
        let raw = "K=\"line1\nline2\""
        let result = parse(raw)
        #expect(result.lines.count == 2)
        // First: unterminated double-quoted value → malformed
        guard case .malformed(_, let reason1) = result.lines[0] else {
            Issue.record("expected first line malformed")
            return
        }
        #expect(reason1.contains("unterminated"))
        // Second: `line2"` — has no `=`, so malformed
        guard case .malformed = result.lines[1] else {
            Issue.record("expected second line malformed")
            return
        }
        #expect(result.warnings.count == 2)
    }

    @Test("leading whitespace before the key is permitted and parses normally")
    func leadingWhitespaceBeforeKey() {
        let raw = "   KEY=value"
        let result = parse(raw)
        #expect(result.lines == [.keyValue(key: "KEY", value: "value", rawText: raw)])
    }

    @Test("bare value ending in backslash (line continuation) is malformed")
    func bareValueBackslashContinuation() {
        let raw = "KEY=value\\"
        let result = parse(raw)
        guard case .malformed(_, let reason) = result.lines[0] else {
            Issue.record("expected .malformed")
            return
        }
        #expect(reason.contains("backslash line continuation"))
    }

    @Test("unterminated backslash escape at end of double-quoted value is malformed")
    func unterminatedBackslashInQuoted() {
        let raw = "KEY=\"value\\"
        let result = parse(raw)
        guard case .malformed(_, let reason) = result.lines[0] else {
            Issue.record("expected .malformed")
            return
        }
        #expect(reason.contains("backslash escape") || reason.contains("unterminated"))
    }

    @Test("bare value with $ is flagged as unsupported interpolation")
    func bareInterpolation() {
        let result = parse("KEY=$OTHER")
        guard case .malformed(_, let reason) = result.lines[0] else {
            Issue.record("expected .malformed")
            return
        }
        #expect(reason.contains("interpolation"))
    }

    // MARK: - Inline comment (unsupported in v1)

    @Test("comment after bare value: v1 treats whole rest of line as value")
    func inlineCommentPartOfValue() {
        let raw = "KEY=value # comment"
        let result = parse(raw)
        #expect(
            result.lines == [
                .keyValue(key: "KEY", value: "value # comment", rawText: raw)
            ])
    }

    // MARK: - Repeated key

    @Test("repeated key: both parse as .keyValue")
    func repeatedKey() {
        let raw = "K=first\nK=second\n"
        let result = parse(raw)
        #expect(result.lines.count == 2)
        #expect(result.lines[0] == .keyValue(key: "K", value: "first", rawText: "K=first"))
        #expect(result.lines[1] == .keyValue(key: "K", value: "second", rawText: "K=second"))
        #expect(result.hadTrailingNewline == true)
    }

    // MARK: - Canonicalize

    @Test("canonicalize bare-safe value emits bare form")
    func canonicalizeBare() {
        #expect(canonicalizeEnvLine(key: "K", value: "simple-value") == "K=simple-value")
    }

    @Test("canonicalize empty value emits KEY= (no quotes)")
    func canonicalizeEmpty() {
        #expect(canonicalizeEnvLine(key: "K", value: "") == "K=")
    }

    @Test("canonicalize value with spaces double-quotes it")
    func canonicalizeSpaces() {
        #expect(canonicalizeEnvLine(key: "K", value: "with spaces") == "K=\"with spaces\"")
    }

    @Test("canonicalize value with # double-quotes it")
    func canonicalizeHash() {
        #expect(canonicalizeEnvLine(key: "K", value: "a#b") == "K=\"a#b\"")
    }

    @Test("canonicalize value with $ double-quotes it")
    func canonicalizeDollar() {
        #expect(canonicalizeEnvLine(key: "K", value: "$FOO") == "K=\"$FOO\"")
    }

    @Test("canonicalize escapes backslash, double-quote, newline, tab")
    func canonicalizeEscapes() {
        let out = canonicalizeEnvLine(key: "K", value: "a\\b\"c\nd\te")
        #expect(out == "K=\"a\\\\b\\\"c\\nd\\te\"")
    }

    // MARK: - Render round-trip

    @Test("render lines back preserves file bytes for non-owned content")
    func renderRoundTrip() {
        let source = "# top\nA=1\nB=\"two\"\n# tail\n"
        let result = parse(source)
        let rendered = renderEnvLines(result.lines, withTrailingNewline: result.hadTrailingNewline)
        #expect(rendered == source)
    }

    @Test("render lines without trailing newline reproduces exact input")
    func renderRoundTripNoTrailingNewline() {
        let source = "A=1\nB=2"
        let result = parse(source)
        let rendered = renderEnvLines(result.lines, withTrailingNewline: result.hadTrailingNewline)
        #expect(rendered == source)
    }

    // MARK: - parseEnvFile

    @Test("parseEnvFile reads a file from disk and returns the same ParseResult")
    func parseEnvFileRoundTrip() throws {
        try VaultTestSupport.withEphemeralProjectDirectory { dir in
            let url = dir.appendingPathComponent(".env")
            let source = "A=1\n# comment\nB=two\n"
            try source.write(to: url, atomically: true, encoding: .utf8)
            let result = try parseEnvFile(at: url)
            #expect(result.lines.count == 3)
            #expect(result.warnings.isEmpty)
            #expect(result.hadTrailingNewline == true)
        }
    }

    @Test("parseEnvFile throws envParseFailed when the file cannot be read")
    func parseEnvFileMissingFile() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharibako-missing-\(UUID().uuidString).env")
        #expect(throws: VaultError.self) {
            _ = try parseEnvFile(at: missing)
        }
    }
}
