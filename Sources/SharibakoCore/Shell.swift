import Foundation

/// Result of a completed subprocess invocation.
///
/// Captures the exit code and full stdout / stderr as UTF-8 strings.
/// Non-zero exit codes are not thrown; callers inspect `exitCode`.
internal struct ShellResult {
    internal let exitCode: Int32
    internal let stdout: String
    internal let stderr: String
}

/// Reads a pipe to EOF on a background thread so a chatty child can never fill
/// the kernel pipe buffer (~64 KiB) and block while the parent is waiting on it
/// — the classic `waitUntilExit`-before-read deadlock.
internal final class PipeDrain: @unchecked Sendable {
    // @unchecked Sendable: `data` is written exactly once on the background
    // queue before `semaphore.signal()`, and read only after `wait()` returns —
    // the semaphore provides the happens-before edge.
    private var data = Data()
    private let semaphore = DispatchSemaphore(value: 0)

    /// Starts draining `handle` immediately on a background queue.
    internal init(_ handle: FileHandle) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            data = handle.readDataToEndOfFile()
            semaphore.signal()
        }
    }

    /// Blocks until the pipe reaches EOF, then returns everything it produced.
    internal func drainedData() -> Data {
        semaphore.wait()
        return data
    }
}

/// Internal subprocess helper. `SharibakoCore` shells out to `age` (this ho)
/// and `git` (Conduit, ho-02) through this single surface rather than
/// scattering `Process` boilerplate at each call site.
internal enum Shell {
    /// Fixed fallback directories, probed after `PATH`.
    ///
    /// Homebrew on Apple Silicon and Intel, Linuxbrew, and the system fallback.
    /// These keep GUI-launched contexts working, where the inherited `PATH` is
    /// minimal (ho-04.12 D6). The first hit wins.
    private static let searchPaths: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/home/linuxbrew/.linuxbrew/bin",
        "/usr/bin",
    ]

    /// Locates a named executable, honoring `PATH` first (ho-04.12 D6).
    ///
    /// - Parameter name: The binary name (e.g. `"age"`, `"git"`).
    /// - Returns: URL of the first matching executable.
    /// - Throws: `VaultError.shellNotFound(name:)` if no candidate exists.
    internal static func findExecutable(_ name: String) throws -> URL {
        try findExecutable(name, pathVariable: ProcessInfo.processInfo.environment["PATH"])
    }

    /// `PATH`-first executable lookup with the fixed list as fallback.
    ///
    /// `PATH` is honored first so the code matches the "on PATH" contract the
    /// error text and CLAUDE.md already stated; the fixed ``searchPaths`` follow.
    /// A poisoned `PATH` could serve a hostile `age`, but anyone who can edit
    /// `PATH` can already alias `sharibako` itself (SECURITY.md).
    ///
    /// `pathVariable` is injected so the search order is testable without
    /// mutating the process environment. Empty `PATH` entries are dropped rather
    /// than treated as the current directory.
    internal static func findExecutable(_ name: String, pathVariable: String?) throws -> URL {
        let fileManager = FileManager.default
        let pathDirs = (pathVariable ?? "").split(separator: ":").map(String.init)
        for directory in pathDirs + searchPaths {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw VaultError.shellNotFound(name: name)
    }

    /// Runs an external binary and captures its output.
    ///
    /// Does not throw on non-zero exit codes; callers inspect `ShellResult`.
    /// Only throws if `Process.run()` itself fails to launch. Both pipes are
    /// drained concurrently while the child runs, so output larger than the
    /// kernel pipe buffer cannot deadlock the invocation.
    ///
    /// - Parameters:
    ///   - executableURL: Absolute URL of the binary to run.
    ///   - arguments: Command-line arguments (excluding argv[0]).
    ///   - workingDirectory: Optional directory to set as the process's working directory.
    ///     When `nil` (the default), the process inherits the caller's working directory.
    ///   - environmentOverrides: Variables merged over the inherited environment
    ///     (override wins). When `nil` (the default), the child inherits the
    ///     caller's environment untouched.
    ///   - stdin: Bytes piped to the child's standard input, followed by EOF.
    ///     When `nil` (the default), the child inherits the caller's stdin.
    ///     The write happens on a background queue — the mirror image of
    ///     `PipeDrain` — so a payload larger than the kernel pipe buffer can
    ///     never deadlock against a child that is simultaneously producing
    ///     output.
    /// - Returns: The captured `ShellResult`.
    /// - Throws: Any error thrown by `Process.run()` (typically wrapped `POSIXError`).
    internal static func run(
        _ executableURL: URL,
        _ arguments: [String],
        workingDirectory: URL? = nil,
        environmentOverrides: [String: String]? = nil,
        stdin: Data? = nil
    ) throws -> ShellResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }
        if let environmentOverrides {
            process.environment = ProcessInfo.processInfo.environment
                .merging(environmentOverrides) { _, override in override }
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinPipe: Pipe?
        if stdin != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            stdinPipe = nil
        }

        try process.run()

        if let stdin, let stdinPipe {
            let writeHandle = stdinPipe.fileHandleForWriting
            // A child that exits without draining its stdin would otherwise
            // deliver SIGPIPE to THIS process on write, killing the CLI.
            // F_SETNOSIGPIPE converts that to a plain EPIPE error, which the
            // write below deliberately swallows — the child's exit code is
            // the authoritative signal of what went wrong.
            _ = fcntl(writeHandle.fileDescriptor, F_SETNOSIGPIPE, 1)
            DispatchQueue.global(qos: .userInitiated).async {
                try? writeHandle.write(contentsOf: stdin)
                try? writeHandle.close()
            }
        }

        let stdoutDrain = PipeDrain(stdoutPipe.fileHandleForReading)
        let stderrDrain = PipeDrain(stderrPipe.fileHandleForReading)
        let stdoutData = stdoutDrain.drainedData()
        let stderrData = stderrDrain.drainedData()
        process.waitUntilExit()

        return ShellResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}
