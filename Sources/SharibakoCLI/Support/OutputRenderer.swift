import Foundation

/// ANSI escape sequences for terminal colour output.
private enum ANSI {
    static let reset = "\u{1B}[0m"
    static let bold = "\u{1B}[1m"
    static let red = "\u{1B}[31m"
    static let green = "\u{1B}[32m"
    static let yellow = "\u{1B}[33m"
    static let cyan = "\u{1B}[36m"
}

/// Formats strings for human or JSON output.
///
/// All methods return a `String` — callers decide where to print it. This keeps
/// the renderer testable without redirecting file descriptors.
struct OutputRenderer {
    /// `true` when `--json` was supplied.
    let json: Bool

    /// `true` when stdout is a TTY and colour output is appropriate.
    let color: Bool

    /// Returns `str` unchanged (for plain text lines that need no decoration).
    func text(_ str: String) -> String { str }

    /// Returns `str` styled as a warning (yellow in colour mode).
    func warn(_ str: String) -> String {
        guard color else { return "Warning: \(str)" }
        return "\(ANSI.yellow)Warning: \(str)\(ANSI.reset)"
    }

    /// Returns `str` styled as a success message (green in colour mode).
    func success(_ str: String) -> String {
        guard color else { return str }
        return "\(ANSI.green)\(str)\(ANSI.reset)"
    }

    /// Returns `str` styled as an error (red in colour mode).
    func error(_ str: String) -> String {
        guard color else { return "Error: \(str)" }
        return "\(ANSI.red)Error: \(str)\(ANSI.reset)"
    }

    /// Returns a `key: value` pair formatted for terminal display.
    func kv(_ key: String, _ value: String) -> String {
        guard color else { return "\(key): \(value)" }
        return "\(ANSI.bold)\(key)\(ANSI.reset): \(value)"
    }

    /// Renders a table with column headers and rows, aligning columns to the widest cell.
    func table(headers: [String], rows: [[String]]) -> String {
        guard !headers.isEmpty else { return "" }
        // Calculate column widths.
        var widths = headers.map(\.count)
        for row in rows {
            for (idx, cell) in row.enumerated() where idx < widths.count {
                widths[idx] = max(widths[idx], cell.count)
            }
        }

        func formatRow(_ cells: [String], bold: Bool) -> String {
            let padded = cells.enumerated().map { idx, cell in
                cell.padding(toLength: widths[idx], withPad: " ", startingAt: 0)
            }
            let joined = padded.joined(separator: "  ")
            guard color, bold else { return joined }
            return "\(ANSI.bold)\(joined)\(ANSI.reset)"
        }

        var lines = [formatRow(headers, bold: true)]
        if color {
            lines.append(widths.map { String(repeating: "─", count: $0) }.joined(separator: "  "))
        } else {
            lines.append(widths.map { String(repeating: "-", count: $0) }.joined(separator: "  "))
        }
        for row in rows {
            // Pad to headers count so short rows don't panic.
            var padded = row
            while padded.count < headers.count { padded.append("") }
            lines.append(formatRow(Array(padded.prefix(headers.count)), bold: false))
        }
        return lines.joined(separator: "\n")
    }

    /// JSON-encodes `payload` using `JSONEncoder` with sorted keys for stability.
    ///
    /// - Throws: Any `EncodingError` from `JSONEncoder`.
    func encodeJSON<T: Encodable>(_ payload: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        return String(bytes: data, encoding: .utf8) ?? ""
    }
}
