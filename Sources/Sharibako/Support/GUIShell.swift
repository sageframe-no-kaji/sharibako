import Foundation
import SharibakoCore

/// Result of a `GUIShell.run` invocation.
struct GUIShellResult {
    /// Process exit code.
    let exitCode: Int32
    /// Captured stdout, decoded as UTF-8.
    let stdout: String
    /// Captured stderr, decoded as UTF-8.
    let stderr: String
}

/// Reads a pipe to EOF on a background thread so a chatty child can never
/// fill the kernel pipe buffer and block while the parent is waiting on it.
///
/// Mirrors `PipeDrain` in `SharibakoCore` (internal to that library) and the
/// CLI's own copy in `CLIShell.swift`.
private final class GUIPipeDrain: @unchecked Sendable {
    // @unchecked Sendable: `data` is written exactly once on the background
    // queue before `semaphore.signal()`, and read only after `wait()`
    // returns — the semaphore provides the happens-before edge.
    private var data = Data()
    private let semaphore = DispatchSemaphore(value: 0)

    /// Starts draining `handle` immediately on a background queue.
    init(_ handle: FileHandle) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            data = handle.readDataToEndOfFile()
            semaphore.signal()
        }
    }

    /// Blocks until the pipe reaches EOF, then returns everything it produced.
    func drainedData() -> Data {
        semaphore.wait()
        return data
    }
}

/// Minimal subprocess utilities for the Workshop target.
///
/// Mirrors `Shell` from `SharibakoCore` (internal to that library) the way
/// the CLI's `CLIShell` already does — the wizard needs `age-keygen` (key
/// bootstrap) and `git` (the finish page's identity probe, ho-06.3 Decision
/// 8), and both live outside a bare GUI-launched `PATH`, which is exactly
/// why the fallback list exists (ho-04.12 D6).
enum GUIShell {
    /// Fixed fallback directories, probed after `PATH`.
    ///
    /// Mirrors `Shell.searchPaths` in `SharibakoCore` and `CLIShell.searchPaths`.
    private static let searchPaths: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/home/linuxbrew/.linuxbrew/bin",
        "/usr/bin",
    ]

    /// Finds the named binary, honoring `PATH` first (ho-04.12 D6).
    ///
    /// - Throws: `VaultError.shellNotFound(name:)` if neither `PATH` nor the
    ///   fixed fallback list contains the binary.
    static func findExecutable(_ name: String) throws -> URL {
        try findExecutable(name, pathVariable: ProcessInfo.processInfo.environment["PATH"])
    }

    /// `PATH`-first executable lookup with the fixed list as fallback.
    ///
    /// `pathVariable` is injected so the search order is testable without
    /// mutating the process environment. Empty `PATH` entries are dropped
    /// rather than treated as the current directory.
    static func findExecutable(_ name: String, pathVariable: String?) throws -> URL {
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

    /// Runs a binary and returns exit code, stdout, and stderr as UTF-8 strings.
    ///
    /// Does not throw on non-zero exit; callers inspect `exitCode`. Both
    /// pipes are drained concurrently while the child runs, so output larger
    /// than the kernel pipe buffer cannot deadlock the invocation.
    ///
    /// - Parameters:
    ///   - executableURL: Absolute URL of the binary to run.
    ///   - arguments: Command-line arguments (excluding argv[0]).
    ///   - environmentOverrides: Variables merged over the inherited
    ///     environment (override wins); `nil` (the default) inherits the
    ///     caller's environment untouched. Mirrors `Shell.run`
    ///     (`SharibakoCore`) — the seam `ensureFirstRunGitIdentity`
    ///     (`WorkshopModel+FirstRun.swift`) uses to isolate `git config
    ///     user.email`'s global-config lookup from the real developer
    ///     machine's own git identity in tests.
    /// - Returns: The captured ``GUIShellResult``.
    /// - Throws: Any error thrown by `Process.run()` (typically a wrapped
    ///   `POSIXError`) — never for a non-zero exit code, which callers read
    ///   from the returned result.
    static func run(
        _ executableURL: URL,
        _ arguments: [String],
        environmentOverrides: [String: String]? = nil
    ) throws -> GUIShellResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let environmentOverrides {
            process.environment = ProcessInfo.processInfo.environment
                .merging(environmentOverrides) { _, override in override }
        }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        let stdoutDrain = GUIPipeDrain(stdoutPipe.fileHandleForReading)
        let stderrDrain = GUIPipeDrain(stderrPipe.fileHandleForReading)
        let outData = stdoutDrain.drainedData()
        let errData = stderrDrain.drainedData()
        process.waitUntilExit()
        return GUIShellResult(
            exitCode: process.terminationStatus,
            stdout: String(bytes: outData, encoding: .utf8) ?? "",
            stderr: String(bytes: errData, encoding: .utf8) ?? ""
        )
    }
}
