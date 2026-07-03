import Foundation

#if canImport(Darwin)
    import Darwin
#endif

// MARK: - Module-level terminal state (signal-handler-safe)

/// Saved terminal state written before entering raw mode and read by the
/// SIGINT restore handler. `nil` when no `InteractiveSelect` is active.
///
/// `nonisolated(unsafe)` because the SIGINT handler runs outside any Swift
/// actor context. Access is single-threaded in practice — one interactive
/// prompt at a time — so no lock is needed.
nonisolated(unsafe) private var _savedTermiosForRestore: termios?

/// C-compatible SIGINT handler: restores the saved terminal state then
/// re-raises SIGINT so the process exits with the conventional signal status.
///
/// Not covered in headless CI — real TTY + SIGINT delivery required.
private func _sigintRestoreAndReraise(_ signo: CInt) {
    // Single-character `t` is the conventional termios variable name in raw-mode terminal code.
    // swiftlint:disable:next identifier_name
    if var t = _savedTermiosForRestore {
        tcsetattr(STDIN_FILENO, TCSANOW, &t)
    }
    signal(SIGINT, SIG_DFL)
    raise(SIGINT)
}

/// Puts stdin into raw, non-echoing mode and installs the SIGINT restore handler.
///
/// No-ops silently when stdin is not a TTY (CI / injected-readByte test path).
/// Not covered in headless CI — real TTY required.
private func _enterRawMode() {
    guard isatty(STDIN_FILENO) != 0 else { return }
    // Single-character `t` is the conventional termios variable name in raw-mode terminal code.
    // swiftlint:disable:next identifier_name
    var t = termios()
    tcgetattr(STDIN_FILENO, &t)
    _savedTermiosForRestore = t
    t.c_lflag &= ~(UInt(ICANON) | UInt(ECHO))
    // Set VMIN=1 (block until one byte), VTIME=0 (no timeout).
    withUnsafeMutableBytes(of: &t.c_cc) { ptr in
        ptr[Int(VMIN)] = 1
        ptr[Int(VTIME)] = 0
    }
    tcsetattr(STDIN_FILENO, TCSANOW, &t)
    signal(SIGINT, _sigintRestoreAndReraise)
}

/// Restores the saved terminal state and removes the SIGINT restore handler.
///
/// No-ops when `_savedTermiosForRestore` is nil (non-TTY path).
private func _exitRawMode() {
    // Single-character `t` is the conventional termios variable name in raw-mode terminal code.
    // swiftlint:disable:next identifier_name
    if var t = _savedTermiosForRestore {
        tcsetattr(STDIN_FILENO, TCSANOW, &t)
    }
    signal(SIGINT, SIG_DFL)
    _savedTermiosForRestore = nil
}

// MARK: - InteractiveSelect

/// An arrow-key single-select prompt over a labelled choice list.
///
/// Renders `title` followed by each choice row, with the current selection
/// highlighted via ANSI reverse-video. The user navigates with ↑/↓ and
/// confirms with Enter. Ctrl-C throws ``CLIError/aborted``.
///
/// ## Testability
///
/// Inject `readByte`, `write`, and `isInteractive` to drive the widget
/// without a real terminal. The raw-mode setup (`_enterRawMode` /
/// `_exitRawMode`) gracefully no-ops when stdin is not a TTY, so the
/// injected-byte path runs cleanly in CI. Only the default `readByte`
/// closure body and the raw-mode setup functions are coverage-excluded
/// (real TTY required).
struct InteractiveSelect {
    /// Prompt title printed above the choice list.
    let title: String

    /// Ordered list of choice labels.
    let choices: [String]

    /// Row index to highlight when the prompt first appears.
    var initialIndex: Int = 0

    /// Single-byte source.
    ///
    /// Defaults to a blocking raw-mode read from stdin.
    /// Inject a scripted queue in tests; the raw-mode default is not
    /// covered in headless CI.
    var readByte: () -> UInt8? = {
        // Raw-mode single-byte stdin read. Not covered in headless CI.
        var byte: UInt8 = 0
        let result = Darwin.read(STDIN_FILENO, &byte, 1)
        return result == 1 ? byte : nil
    }

    /// Output sink for renders.
    ///
    /// Defaults to stderr (prompts are UX, not payload).
    var write: (String) -> Void = { fputs($0, stderr) }

    /// TTY guard.
    ///
    /// Defaults to ``TerminalDetector/isInteractiveInput``.
    var isInteractive: () -> Bool = { TerminalDetector.isInteractiveInput }

    /// Runs the prompt and returns the chosen index.
    ///
    /// - Throws: ``CLIError/notInteractiveTerminal`` when `isInteractive()` is
    ///   `false`; ``CLIError/aborted`` on Ctrl-C.
    func run() throws -> Int {
        guard isInteractive() else { throw CLIError.notInteractiveTerminal }
        _enterRawMode()
        defer { _exitRawMode() }
        return try runLoop()
    }

    // MARK: - Private state machine (fully covered via injected readByte/write)

    /// State machine: reads bytes, moves the cursor, returns on Enter.
    private func runLoop() throws -> Int {
        var cursor = max(0, min(initialIndex, choices.count - 1))
        renderFrame(cursor: cursor, isRedraw: false)
        while true {
            guard let byte = readByte() else { continue }
            switch byte {
            case 0x03:
                throw CLIError.aborted
            case 0x0A, 0x0D:
                return cursor
            case 0x1B:
                if handleEscapeSequence(cursor: &cursor) {
                    renderFrame(cursor: cursor, isRedraw: true)
                }
            default:
                break
            }
        }
    }

    /// Parses the `[ A` / `[ B` tail of an arrow-key escape sequence.
    ///
    /// Moves `cursor`, clamping at both ends. Returns `true` when the
    /// cursor actually moved (redraw needed).
    private func handleEscapeSequence(cursor: inout Int) -> Bool {
        guard let bracket = readByte(), bracket == 0x5B else { return false }
        guard let arrow = readByte() else { return false }
        let before = cursor
        switch arrow {
        case 0x41 where cursor > 0:
            cursor -= 1
        case 0x42 where cursor < choices.count - 1:
            cursor += 1
        default:
            break
        }
        return cursor != before
    }

    /// Renders the title and all choice rows, optionally moving the cursor
    /// up first to overwrite the previous frame in place.
    private func renderFrame(cursor: Int, isRedraw: Bool) {
        var out = ""
        if isRedraw {
            // Move cursor up to the title line and overwrite in place.
            out += "\u{1B}[\(choices.count)A\r"
        }
        out += "\u{1B}[K\(title)\n"
        for (index, choice) in choices.enumerated() {
            out += "\r\u{1B}[K"
            if index == cursor {
                out += "\u{1B}[7m> \(choice)\u{1B}[0m"
            } else {
                out += "  \(choice)"
            }
            if index < choices.count - 1 {
                out += "\n"
            }
        }
        write(out)
    }
}
