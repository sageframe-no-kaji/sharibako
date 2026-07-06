import Foundation

/// Stderr-only feedback for `sharibako run` — the startup status line and the
/// signal-shutdown countdown.
///
/// A `Sendable` sink wrapping a line emitter, plus the pure formatters and the
/// TTY/flag gate. `run` prints nothing to stdout (that belongs to the child); every
/// line here goes to stderr, and only when the gate says so. The formatters are pure
/// so they test without a sink; the sink crosses into `SignalForwarder`'s dispatch
/// handlers, which is why it must be `Sendable`.
struct RunFeedback: Sendable {
    private let emitter: @Sendable (String) -> Void

    /// Creates a sink from a line emitter.
    ///
    /// The emitter receives the line with its trailing newline already appended.
    init(emitter: @escaping @Sendable (String) -> Void) {
        self.emitter = emitter
    }

    /// Writes one line (a newline is appended).
    func emit(_ line: String) {
        emitter(line + "\n")
    }

    /// Production sink — writes to stderr.
    static let standardError = Self { line in
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// No-op sink — emits nothing.
    static let disabled = Self { _ in }

    /// The gate decision, factored out as a pure `Bool` so it tests without a sink.
    ///
    /// On when stderr is a TTY; suppressed under `--json` (machine output); forced on
    /// under `--verbose` even when stderr is redirected (the log-capture escape hatch).
    static func shouldEmit(json: Bool, verbose: Bool, isTTY: Bool) -> Bool {
        if json { return false }
        if verbose { return true }
        return isTTY
    }

    /// Picks the sink from the output flags and whether stderr is a terminal.
    static func make(json: Bool, verbose: Bool, isTTY: Bool) -> Self {
        shouldEmit(json: json, verbose: verbose, isTTY: isTTY) ? .standardError : .disabled
    }

    // MARK: - Formatters (pure)

    /// The startup line: scope, count of secrets injected, and the command.
    ///
    /// Count only — never secret names or values. A zero count reads as no secrets
    /// injected, subsuming the former empty-scope note.
    static func startupLine(scope: String, secretCount: Int, command: [String]) -> String {
        // `.captureForPassthrough` keeps the `--` separator in the array; it's a spawn
        // artifact (env swallows it), not part of the command the user typed — drop it
        // for display only.
        let display = command.first == "--" ? Array(command.dropFirst()) : command
        let cmd = display.joined(separator: " ")
        if secretCount == 0 {
            return "sharibako: scope '\(scope)' — no secrets to inject → \(cmd)"
        }
        let noun = secretCount == 1 ? "secret" : "secrets"
        return "sharibako: scope '\(scope)' — \(secretCount) \(noun) → \(cmd)"
    }

    /// Human name for a forwarded signal.
    static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGINT: return "SIGINT"
        case SIGTERM: return "SIGTERM"
        case SIGHUP: return "SIGHUP"
        case SIGQUIT: return "SIGQUIT"
        default: return "signal \(signal)"
        }
    }

    /// Emitted immediately when a signal is forwarded to the child.
    static func forwardingLine(signal: Int32) -> String {
        "sharibako: forwarding \(signalName(signal)) to child…"
    }

    /// One countdown tick — the seconds remaining before SIGKILL.
    static func countdownLine(secondsRemaining: Int) -> String {
        "sharibako: waiting for child to exit… \(secondsRemaining)"
    }

    /// Emitted just before escalating to SIGKILL.
    static func sigkillLine() -> String {
        "sharibako: child unresponsive — sending SIGKILL"
    }
}
