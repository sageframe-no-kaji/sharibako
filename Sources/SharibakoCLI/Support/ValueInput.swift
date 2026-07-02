import Foundation

/// Reads a secret value from `--value <v>` or `--from-stdin`, enforcing mutual exclusivity.
struct ValueInput {
    /// Literal value supplied via `--value`.
    let value: String?

    /// Whether `--from-stdin` was set.
    let fromStdin: Bool

    /// Injectable stdin reader; defaults to reading all bytes from standard input.
    ///
    /// Override in tests to supply controlled input without redirecting the process fd.
    var stdinReader: () -> Data = { FileHandle.standardInput.readDataToEndOfFile() }

    /// Returns the secret value, enforcing that exactly one of `value`/`fromStdin` is set.
    ///
    /// - Throws: `CLIError.valueInputConflict` when both flags are set;
    ///   `CLIError.valueInputRequired` when neither is set.
    func read() throws -> String {
        switch (value, fromStdin) {
        case (.some(let val), false):
            return val
        case (nil, true):
            let raw = stdinReader()
            var text = String(bytes: raw, encoding: .utf8) ?? ""
            if text.hasSuffix("\n") { text.removeLast() }
            return text
        case (.some, true):
            throw CLIError.valueInputConflict
        case (nil, false):
            throw CLIError.valueInputRequired
        }
    }
}
