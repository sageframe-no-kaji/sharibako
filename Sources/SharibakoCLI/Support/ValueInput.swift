import Foundation

/// Reads a secret value from `--value <v>`, `--from-stdin`, or — on a terminal
/// with neither flag — an echo-off interactive prompt (ho-04.11).
struct ValueInput {
    /// Literal value supplied via `--value`.
    let value: String?

    /// Whether `--from-stdin` was set.
    let fromStdin: Bool

    /// Injectable stdin reader; defaults to reading all bytes from standard input.
    ///
    /// Override in tests to supply controlled input without redirecting the process fd.
    var stdinReader: () -> Data = { FileHandle.standardInput.readDataToEndOfFile() }

    /// Echo-off interactive prompt used when neither flag is supplied.
    ///
    /// Defaults to ``SecureValuePrompt/defaultPrompt`` — a hidden-input prompt
    /// on a terminal, `nil` on non-TTY stdin (where flagless invocation stays
    /// an error). Override in tests to script the prompt without a terminal.
    var securePrompt: (() throws -> String)? = SecureValuePrompt.defaultPrompt

    /// Returns the secret value.
    ///
    /// `--value` and `--from-stdin` are mutually exclusive. With neither set,
    /// the secure prompt runs when available — the hygienic default: nothing
    /// in argv, nothing in shell history.
    ///
    /// - Throws: `CLIError.valueInputConflict` when both flags are set;
    ///   `CLIError.valueInputRequired` when neither is set and no interactive
    ///   terminal is available.
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
            guard let securePrompt else {
                throw CLIError.valueInputRequired
            }
            return try securePrompt()
        }
    }
}
