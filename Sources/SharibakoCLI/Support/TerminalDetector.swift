#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Detects whether the process is attached to a colour-capable terminal.
enum TerminalDetector {
    /// `true` when stdout is connected to a TTY (not a pipe or file redirect).
    static var isColorTerminal: Bool { isatty(STDOUT_FILENO) != 0 }
}
