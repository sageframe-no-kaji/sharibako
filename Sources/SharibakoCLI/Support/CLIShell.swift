import Foundation
import SharibakoCore

/// Result of a `CLIShell.run` invocation.
struct CLIShellResult {
    /// Process exit code.
    let exitCode: Int32
    /// Captured stdout, decoded as UTF-8.
    let stdout: String
    /// Captured stderr, decoded as UTF-8.
    let stderr: String
}

/// Reads a pipe to EOF on a background thread so a chatty child can never fill
/// the kernel pipe buffer and block while the parent is waiting on it.
///
/// Mirrors `PipeDrain` in `SharibakoCore` (internal to that library).
private final class PipeDrain: @unchecked Sendable {
    // @unchecked Sendable: `data` is written exactly once on the background
    // queue before `semaphore.signal()`, and read only after `wait()` returns —
    // the semaphore provides the happens-before edge.
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

/// Minimal subprocess utilities for the CLI target.
///
/// Mirrors `Shell` from `SharibakoCore` (which is internal to that library).
/// Only the subset needed by CLI commands — `age-keygen` invocations — lives here.
enum CLIShell {
    /// Fixed fallback directories, probed after `PATH`.
    ///
    /// Kept working for GUI-launched contexts where the inherited `PATH` is
    /// minimal (ho-04.12 D6). Mirrors `Shell.searchPaths` in `SharibakoCore`,
    /// which is internal to that library.
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
    /// mutating the process environment. Empty `PATH` entries are dropped rather
    /// than treated as the current directory. Mirrors `Shell.findExecutable` in
    /// `SharibakoCore` (internal to that library, hence the duplication).
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
    /// Does not throw on non-zero exit; callers inspect `exitCode`. Both pipes
    /// are drained concurrently while the child runs, so output larger than the
    /// kernel pipe buffer cannot deadlock the invocation (mirrors `Shell.run`).
    static func run(_ executableURL: URL, _ arguments: [String]) throws -> CLIShellResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        let stdoutDrain = PipeDrain(stdoutPipe.fileHandleForReading)
        let stderrDrain = PipeDrain(stderrPipe.fileHandleForReading)
        let outData = stdoutDrain.drainedData()
        let errData = stderrDrain.drainedData()
        process.waitUntilExit()
        return CLIShellResult(
            exitCode: process.terminationStatus,
            stdout: String(bytes: outData, encoding: .utf8) ?? "",
            stderr: String(bytes: errData, encoding: .utf8) ?? ""
        )
    }
}
