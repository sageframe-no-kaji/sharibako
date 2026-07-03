import Foundation

/// Structured representation of a single line in a `.env`-style file.
///
/// Every line the parser reads becomes exactly one `EnvLine`. Non-owned lines
/// pass through the Materializer byte-for-byte via each case's stored raw text —
/// including the `\r` of a CRLF terminator, which is stored with the line's
/// text so a CRLF file round-trips without a wholesale line-ending rewrite
/// (ho-04.10). Key/value *content* is always parsed from the CR-free form.
internal enum EnvLine: Sendable, Equatable {
    /// Empty line or whitespace-only line.
    case blank(text: String)
    /// Line whose first non-whitespace character is `#`.
    case comment(text: String)
    /// Parsed `KEY=value` line. `rawText` preserves the original bytes.
    case keyValue(key: String, value: String, rawText: String)
    /// Line the parser rejected. Preserved byte-for-byte and surfaced as a `ParseWarning`.
    case malformed(text: String, reason: String)

    /// The raw text used for round-trip rendering.
    internal var text: String {
        switch self {
        case .blank(let text), .comment(let text), .malformed(let text, _):
            return text
        case .keyValue(_, _, let rawText):
            return rawText
        }
    }

    /// `true` when this line's stored text carries the `\r` of a CRLF terminator.
    internal var endsWithCR: Bool {
        text.hasSuffix("\r")
    }

    /// Re-attaches the `\r` of a CRLF-terminated source line to the stored text.
    internal func appendingCarriageReturn() -> Self {
        switch self {
        case .blank(let text):
            return .blank(text: text + "\r")
        case .comment(let text):
            return .comment(text: text + "\r")
        case .malformed(let text, let reason):
            return .malformed(text: text + "\r", reason: reason)
        case .keyValue(let key, let value, let rawText):
            return .keyValue(key: key, value: value, rawText: rawText + "\r")
        }
    }

    /// Strips a trailing `\r` from the stored text; no-op when none is present.
    internal func removingCarriageReturn() -> Self {
        guard endsWithCR else { return self }
        switch self {
        case .blank(let text):
            return .blank(text: String(text.dropLast()))
        case .comment(let text):
            return .comment(text: String(text.dropLast()))
        case .malformed(let text, let reason):
            return .malformed(text: String(text.dropLast()), reason: reason)
        case .keyValue(let key, let value, let rawText):
            return .keyValue(key: key, value: value, rawText: String(rawText.dropLast()))
        }
    }
}

/// Structured result of parsing an `.env`-style file or string.
///
/// - `lines`: one entry per source line, in order.
/// - `warnings`: non-fatal issues (BOM stripped, malformed line, unterminated quote, …).
/// - `hadTrailingNewline`: `true` when the input's last byte was `\n` — the renderer uses
///   this to preserve trailing-newline state exactly.
internal struct ParseResult: Sendable, Equatable {
    internal let lines: [EnvLine]
    internal let warnings: [ParseWarning]
    internal let hadTrailingNewline: Bool
}

/// Reads a `.env`-style file from disk and parses it.
///
/// Throws only when the file itself is fundamentally unreadable (encoding failure, IO error).
/// Malformed lines never throw; they surface as `ParseWarning` values in the result.
internal func parseEnvFile(at url: URL) throws -> ParseResult {
    let text: String
    do {
        text = try String(contentsOf: url, encoding: .utf8)
    } catch {
        throw VaultError.envParseFailed(path: url, reason: "\(error)")
    }
    return parseEnvString(text, sourceFile: url)
}

/// Parses an in-memory `.env`-style string, tagging warnings with `sourceFile`.
internal func parseEnvString(_ text: String, sourceFile: URL) -> ParseResult {
    var working = text
    var warnings: [ParseWarning] = []

    if working.hasPrefix("\u{FEFF}") {
        working.removeFirst()
        warnings.append(
            ParseWarning(
                file: sourceFile,
                lineNumber: 1,
                text: "",
                reason: "UTF-8 BOM stripped from start of file."
            )
        )
    }

    if working.isEmpty {
        return ParseResult(lines: [], warnings: warnings, hadTrailingNewline: false)
    }

    // Check for trailing LF at the byte level so CRLF-terminated files (whose last
    // grapheme cluster is "\r\n") still get detected. Then strip via unicodeScalars
    // to remove only the LF and preserve any trailing CR that belongs to the CRLF.
    let hadTrailingNewline = working.unicodeScalars.last == "\n"
    if hadTrailingNewline {
        working.unicodeScalars.removeLast()
    }

    let rawSegments = working.components(separatedBy: "\n")
    var lines: [EnvLine] = []
    for (idx, segment) in rawSegments.enumerated() {
        // Parse content CR-free, but store the CR with the line (ho-04.10):
        // render joins with "\n", so the stored "\r" reproduces the CRLF.
        let hadCR = segment.hasSuffix("\r")
        let content = hadCR ? String(segment.dropLast()) : segment
        let parsed = parseEnvLine(content, sourceFile: sourceFile, lineNumber: idx + 1)
        lines.append(hadCR ? parsed.line.appendingCarriageReturn() : parsed.line)
        warnings.append(contentsOf: parsed.warnings)
    }
    return ParseResult(lines: lines, warnings: warnings, hadTrailingNewline: hadTrailingNewline)
}

/// `true` when `lines` are predominantly CRLF-terminated.
///
/// Drives the terminator choice for lines the Materializer appends. Half-or-more
/// CR-bearing lines (with at least one) counts as CRLF — a file missing its final
/// newline under-counts by one, so ties break toward CRLF. Empty input is LF.
internal func dominantLineEndingIsCRLF(_ lines: [EnvLine]) -> Bool {
    let crCount = lines.count(where: \.endsWithCR)
    return crCount > 0 && crCount * 2 >= lines.count
}

/// Renders a list of `EnvLine`s back to text.
///
/// Joins line texts with `\n` and appends a trailing `\n` when `withTrailingNewline`
/// is `true`. Mirrors the split behavior of `parseEnvString` byte-for-byte —
/// including files that end with an actual blank line (`"A=1\n\n"`), whose last
/// `EnvLine` is `.blank("")` and whose terminating `\n` is separately tracked.
internal func renderEnvLines(_ lines: [EnvLine], withTrailingNewline: Bool) -> String {
    var output = lines.map(\.text).joined(separator: "\n")
    if withTrailingNewline {
        output += "\n"
    }
    return output
}

/// Builds a canonical `KEY=value` line for an owned key's rewrite.
///
/// Bare when no character needs quoting. Values containing `$` prefer single
/// quotes — the one quoting style docker-compose, the dotenv family, and this
/// parser all read literally, where double quotes invite interpolation this
/// parser can't see (ho-04.10). A `$`-bearing value that also holds a single
/// quote or newline falls back to double quotes with `$` escaped as `\$`
/// (read back as `$` by this parser; downstream support for the escape is
/// less universal, which is why the single-quoted form leads). Everything
/// else quotes double, escaping `\\`, `"`, `\n`, `\t`.
internal func canonicalizeEnvLine(key: String, value: String) -> String {
    if value.isEmpty {
        return "\(key)="
    }
    let needsQuoting = value.contains { char in
        char.isWhitespace || char == "\"" || char == "'" || char == "\\"
            || char == "#" || char == "$"
    }
    if !needsQuoting {
        return "\(key)=\(value)"
    }
    if value.contains("$"), !value.contains("'"), !value.contains("\n") {
        return "\(key)='\(value)'"
    }
    var escaped = ""
    for char in value {
        switch char {
        case "\\": escaped += "\\\\"
        case "\"": escaped += "\\\""
        case "\n": escaped += "\\n"
        case "\t": escaped += "\\t"
        case "$": escaped += "\\$"
        default: escaped.append(char)
        }
    }
    return "\(key)=\"\(escaped)\""
}

/// Returns the key a line *intends* — the `[A-Za-z_][A-Za-z0-9_]*` run before
/// the first `=`, after optional whitespace and an `export ` prefix — regardless
/// of whether the rest of the line parses. Mirrors `parseKeyValueLine`'s prefix
/// walk. The Materializer uses this to recognize a corrupted owned line
/// (ho-04.10): a malformed line whose intended key is owned counts as drift
/// and is rewritten in place rather than passed through.
internal func envLineIntendedKey(_ text: String) -> String? {
    var idx = text.startIndex
    while idx < text.endIndex, text[idx].isWhitespace {
        idx = text.index(after: idx)
    }
    let exportKeyword = "export"
    if text[idx...].hasPrefix(exportKeyword) {
        let afterExport = text.index(idx, offsetBy: exportKeyword.count)
        if afterExport < text.endIndex, text[afterExport].isWhitespace {
            idx = afterExport
            while idx < text.endIndex, text[idx].isWhitespace {
                idx = text.index(after: idx)
            }
        }
    }
    guard idx < text.endIndex, isKeyStart(text[idx]) else { return nil }
    let keyStart = idx
    while idx < text.endIndex, isKeyRest(text[idx]) {
        idx = text.index(after: idx)
    }
    guard idx < text.endIndex, text[idx] == "=" else { return nil }
    return String(text[keyStart..<idx])
}

// MARK: - Line-level parsing

private struct ParsedLine {
    let line: EnvLine
    let warnings: [ParseWarning]
}

private func parseEnvLine(_ raw: String, sourceFile: URL, lineNumber: Int) -> ParsedLine {
    if raw.allSatisfy({ $0.isWhitespace }) {
        return ParsedLine(line: .blank(text: raw), warnings: [])
    }
    let firstNonWhitespace = raw.first { !$0.isWhitespace }
    if firstNonWhitespace == "#" {
        return ParsedLine(line: .comment(text: raw), warnings: [])
    }
    return parseKeyValueLine(raw, sourceFile: sourceFile, lineNumber: lineNumber)
}

private func parseKeyValueLine(
    _ raw: String,
    sourceFile: URL,
    lineNumber: Int
) -> ParsedLine {
    var idx = raw.startIndex
    while idx < raw.endIndex, raw[idx].isWhitespace {
        idx = raw.index(after: idx)
    }
    // Optional `export ` prefix (any amount of whitespace between `export` and the key).
    let exportKeyword = "export"
    if raw[idx...].hasPrefix(exportKeyword) {
        let afterExport = raw.index(idx, offsetBy: exportKeyword.count)
        if afterExport < raw.endIndex, raw[afterExport].isWhitespace {
            idx = afterExport
            while idx < raw.endIndex, raw[idx].isWhitespace {
                idx = raw.index(after: idx)
            }
        }
    }
    // Key must start with [A-Za-z_].
    guard idx < raw.endIndex, isKeyStart(raw[idx]) else {
        return malformed(
            raw: raw,
            reason: "line does not begin with a valid key ([A-Za-z_][A-Za-z0-9_]*)",
            sourceFile: sourceFile,
            lineNumber: lineNumber
        )
    }
    let keyStart = idx
    while idx < raw.endIndex, isKeyRest(raw[idx]) {
        idx = raw.index(after: idx)
    }
    let key = String(raw[keyStart..<idx])
    guard idx < raw.endIndex, raw[idx] == "=" else {
        return malformed(
            raw: raw,
            reason: "expected '=' after key '\(key)'",
            sourceFile: sourceFile,
            lineNumber: lineNumber
        )
    }
    idx = raw.index(after: idx)
    return parseValue(
        raw: raw,
        key: key,
        cursor: idx,
        sourceFile: sourceFile,
        lineNumber: lineNumber
    )
}

private func parseValue(
    raw: String,
    key: String,
    cursor: String.Index,
    sourceFile: URL,
    lineNumber: Int
) -> ParsedLine {
    let rest = raw[cursor...]
    guard let first = rest.first else {
        return ParsedLine(line: .keyValue(key: key, value: "", rawText: raw), warnings: [])
    }
    let afterFirst = raw.index(after: cursor)
    if first == "\"" {
        return parseDoubleQuoted(
            raw: raw,
            key: key,
            cursor: afterFirst,
            sourceFile: sourceFile,
            lineNumber: lineNumber
        )
    }
    if first == "'" {
        return parseSingleQuoted(
            raw: raw,
            key: key,
            cursor: afterFirst,
            sourceFile: sourceFile,
            lineNumber: lineNumber
        )
    }
    let bare = String(rest)
    if bare.contains("$") {
        return malformed(
            raw: raw,
            reason: "unsupported interpolation: unquoted '$' in value",
            sourceFile: sourceFile,
            lineNumber: lineNumber
        )
    }
    if bare.hasSuffix("\\") {
        return malformed(
            raw: raw,
            reason: "backslash line continuation is not supported",
            sourceFile: sourceFile,
            lineNumber: lineNumber
        )
    }
    return ParsedLine(line: .keyValue(key: key, value: bare, rawText: raw), warnings: [])
}

private func parseDoubleQuoted(
    raw: String,
    key: String,
    cursor: String.Index,
    sourceFile: URL,
    lineNumber: Int
) -> ParsedLine {
    var result = ""
    var warnings: [ParseWarning] = []
    var idx = cursor
    while idx < raw.endIndex {
        let char = raw[idx]
        if char == "\\" {
            let next = raw.index(after: idx)
            guard next < raw.endIndex else {
                return malformed(
                    raw: raw,
                    reason: "unterminated backslash escape in double-quoted value",
                    sourceFile: sourceFile,
                    lineNumber: lineNumber
                )
            }
            switch raw[next] {
            case "\\": result += "\\"
            case "\"": result += "\""
            case "n": result += "\n"
            case "t": result += "\t"
            case "$": result += "$"
            default:
                // Keeps the character and drops the backslash (historical
                // behavior) — but visibly, not silently (ho-04.10).
                warnings.append(
                    ParseWarning(
                        file: sourceFile,
                        lineNumber: lineNumber,
                        text: raw,
                        reason: "unknown escape '\\\(raw[next])' in double-quoted value — backslash dropped"
                    )
                )
                result.append(raw[next])
            }
            idx = raw.index(after: next)
            continue
        }
        if char == "\"" {
            if let junk = postQuoteJunkWarning(
                raw: raw, closingQuote: idx, sourceFile: sourceFile, lineNumber: lineNumber
            ) {
                warnings.append(junk)
            }
            return ParsedLine(
                line: .keyValue(key: key, value: result, rawText: raw), warnings: warnings
            )
        }
        result.append(char)
        idx = raw.index(after: idx)
    }
    return malformed(
        raw: raw,
        reason: "unterminated double-quoted value",
        sourceFile: sourceFile,
        lineNumber: lineNumber
    )
}

private func parseSingleQuoted(
    raw: String,
    key: String,
    cursor: String.Index,
    sourceFile: URL,
    lineNumber: Int
) -> ParsedLine {
    var result = ""
    var idx = cursor
    while idx < raw.endIndex {
        let char = raw[idx]
        if char == "'" {
            var warnings: [ParseWarning] = []
            if let junk = postQuoteJunkWarning(
                raw: raw, closingQuote: idx, sourceFile: sourceFile, lineNumber: lineNumber
            ) {
                warnings.append(junk)
            }
            return ParsedLine(
                line: .keyValue(key: key, value: result, rawText: raw), warnings: warnings
            )
        }
        result.append(char)
        idx = raw.index(after: idx)
    }
    return malformed(
        raw: raw,
        reason: "unterminated single-quoted value",
        sourceFile: sourceFile,
        lineNumber: lineNumber
    )
}

/// Warns when text follows a value's closing quote (ho-04.10).
///
/// The remainder is not part of the parsed value and never was — the warning
/// makes the swallow visible. A trailing comment (`#` after whitespace) stays
/// silent: it's a common, unambiguous idiom and round-trips via `rawText`.
private func postQuoteJunkWarning(
    raw: String,
    closingQuote: String.Index,
    sourceFile: URL,
    lineNumber: Int
) -> ParseWarning? {
    let rest = raw[raw.index(after: closingQuote)...].drop(while: \.isWhitespace)
    if rest.isEmpty || rest.hasPrefix("#") {
        return nil
    }
    return ParseWarning(
        file: sourceFile,
        lineNumber: lineNumber,
        text: raw,
        reason: "text after the closing quote is not part of the value and is ignored"
    )
}

private func malformed(
    raw: String,
    reason: String,
    sourceFile: URL,
    lineNumber: Int
) -> ParsedLine {
    let warning = ParseWarning(
        file: sourceFile,
        lineNumber: lineNumber,
        text: raw,
        reason: reason
    )
    return ParsedLine(line: .malformed(text: raw, reason: reason), warnings: [warning])
}

private func isKeyStart(_ char: Character) -> Bool {
    (char >= "A" && char <= "Z") || (char >= "a" && char <= "z") || char == "_"
}

private func isKeyRest(_ char: Character) -> Bool {
    isKeyStart(char) || (char >= "0" && char <= "9")
}
