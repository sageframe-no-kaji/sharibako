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

/// Minimal subprocess utilities for the CLI target.
///
/// Mirrors `Shell` from `SharibakoCore` (which is internal to that library).
/// Only the subset needed by CLI commands — `age-keygen` invocations — lives here.
enum CLIShell {
    /// Standard locations searched in priority order.
    private static let searchPaths: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/home/linuxbrew/.linuxbrew/bin",
        "/usr/bin",
    ]

    /// Finds the named binary on the standard search paths.
    ///
    /// - Throws: `VaultError.shellNotFound(name:)` if none of the paths contain the binary.
    static func findExecutable(_ name: String) throws -> URL {
        let fileManager = FileManager.default
        for directory in searchPaths {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw VaultError.shellNotFound(name: name)
    }

    /// Runs a binary and returns exit code, stdout, and stderr as UTF-8 strings.
    ///
    /// Does not throw on non-zero exit; callers inspect `exitCode`.
    static func run(_ executableURL: URL, _ arguments: [String]) throws -> CLIShellResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        return CLIShellResult(
            exitCode: process.terminationStatus,
            stdout: String(bytes: outData, encoding: .utf8) ?? "",
            stderr: String(bytes: errData, encoding: .utf8) ?? ""
        )
    }
}
