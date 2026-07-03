import Foundation

/// Structured representation of a single line in a `.env`-style file.
///
/// Every line the parser reads becomes exactly one `EnvLine`. Non-owned lines
/// pass through the Materializer byte-for-byte via each case's stored raw text.
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
        var lineText = segment
        if lineText.hasSuffix("\r") {
            lineText = String(lineText.dropLast())
        }
        let parsed = parseEnvLine(lineText, sourceFile: sourceFile, lineNumber: idx + 1)
        lines.append(parsed.line)
        if let warning = parsed.warning {
            warnings.append(warning)
        }
    }
    return ParseResult(lines: lines, warnings: warnings, hadTrailingNewline: hadTrailingNewline)
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
/// Quotes with double quotes when the value contains whitespace, quotes, backslash,
/// `#`, `$`, or newline; escapes `\\`, `"`, `\n`, `\t` inside the quoted form.
/// Otherwise emits bare `KEY=value`.
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
    var escaped = ""
    for char in value {
        switch char {
        case "\\": escaped += "\\\\"
        case "\"": escaped += "\\\""
        case "\n": escaped += "\\n"
        case "\t": escaped += "\\t"
        default: escaped.append(char)
        }
    }
    return "\(key)=\"\(escaped)\""
}

// MARK: - Line-level parsing

private struct ParsedLine {
    let line: EnvLine
    let warning: ParseWarning?
}

private func parseEnvLine(_ raw: String, sourceFile: URL, lineNumber: Int) -> ParsedLine {
    if raw.allSatisfy({ $0.isWhitespace }) {
        return ParsedLine(line: .blank(text: raw), warning: nil)
    }
    let firstNonWhitespace = raw.first { !$0.isWhitespace }
    if firstNonWhitespace == "#" {
        return ParsedLine(line: .comment(text: raw), warning: nil)
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
        return ParsedLine(line: .keyValue(key: key, value: "", rawText: raw), warning: nil)
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
    return ParsedLine(line: .keyValue(key: key, value: bare, rawText: raw), warning: nil)
}

private func parseDoubleQuoted(
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
            default: result.append(raw[next])
            }
            idx = raw.index(after: next)
            continue
        }
        if char == "\"" {
            return ParsedLine(line: .keyValue(key: key, value: result, rawText: raw), warning: nil)
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
            return ParsedLine(line: .keyValue(key: key, value: result, rawText: raw), warning: nil)
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
    return ParsedLine(line: .malformed(text: raw, reason: reason), warning: warning)
}

private func isKeyStart(_ char: Character) -> Bool {
    (char >= "A" && char <= "Z") || (char >= "a" && char <= "z") || char == "_"
}

private func isKeyRest(_ char: Character) -> Bool {
    isKeyStart(char) || (char >= "0" && char <= "9")
}
