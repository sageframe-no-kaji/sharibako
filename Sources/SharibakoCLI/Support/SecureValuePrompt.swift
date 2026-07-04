import Foundation

/// Echo-off interactive secret entry (ho-04.11).
///
/// The default value path for `add`/`rotate` on a terminal: nothing lands in
/// argv (visible to `ps`), nothing lands in shell history — the two exposures
/// `--value` carries (see SECURITY.md). The prompt goes to stderr like every
/// other prompt in the CLI; the typed value is read with terminal echo
/// disabled, the way password prompts do it.
///
/// Every path here requires a controlling terminal, so the type is on the CI
/// coverage exclusion list with the same justification as `TerminalDetector`:
/// unreachable under CI's pipes by design, not under-tested.
enum SecureValuePrompt {
    /// The default prompt closure for ``ValueInput``: echo-off entry when
    /// stdin is a terminal, `nil` otherwise (non-TTY callers keep the
    /// `valueInputRequired` error and its `--value`/`--from-stdin` remediation).
    static var defaultPrompt: (() throws -> String)? {
        guard TerminalDetector.isInteractiveInput else { return nil }
        return { try read(prompt: "Value (input hidden): ") }
    }

    /// Reads one line from stdin with echo disabled, restoring the terminal
    /// state before returning.
    static func read(prompt: String) throws -> String {
        fputs(prompt, stderr)
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            throw CLIError.valueInputRequired
        }
        var noEcho = original
        noEcho.c_lflag &= ~tcflag_t(ECHO)
        guard tcsetattr(STDIN_FILENO, TCSANOW, &noEcho) == 0 else {
            throw CLIError.valueInputRequired
        }
        defer {
            var restore = original
            tcsetattr(STDIN_FILENO, TCSANOW, &restore)
            // Echo was off when the user pressed Enter — supply the newline.
            fputs("\n", stderr)
        }
        guard let line = readLine() else {
            throw CLIError.valueInputRequired
        }
        return line
    }
}
