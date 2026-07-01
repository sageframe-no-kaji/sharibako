import Foundation

/// Result of a completed subprocess invocation.
///
/// Captures the exit code and full stdout / stderr as UTF-8 strings.
/// Non-zero exit codes are not thrown; callers inspect `exitCode`.
struct ShellResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

/// Internal subprocess helper. `SharibakoCore` shells out to `age` (this ho)
/// and `git` (Conduit, ho-02) through this single surface rather than
/// scattering `Process` boilerplate at each call site.
enum Shell {
    /// Paths probed in order when locating an external binary.
    ///
    /// Homebrew on Apple Silicon and Intel, Linuxbrew, and the system fallback.
    /// The first hit wins.
    private static let searchPaths: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/home/linuxbrew/.linuxbrew/bin",
        "/usr/bin",
    ]

    /// Locates a named executable on the standard search paths.
    ///
    /// - Parameter name: The binary name (e.g. `"age"`, `"git"`).
    /// - Returns: URL of the first matching executable.
    /// - Throws: `VaultError.shellNotFound(name:)` if no candidate exists.
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

    /// Runs an external binary and captures its output.
    ///
    /// Does not throw on non-zero exit codes; callers inspect `ShellResult`.
    /// Only throws if `Process.run()` itself fails to launch.
    ///
    /// - Parameters:
    ///   - executableURL: Absolute URL of the binary to run.
    ///   - arguments: Command-line arguments (excluding argv[0]).
    ///   - workingDirectory: Optional directory to set as the process's working directory.
    ///     When `nil` (the default), the process inherits the caller's working directory.
    /// - Returns: The captured `ShellResult`.
    /// - Throws: Any error thrown by `Process.run()` (typically wrapped `POSIXError`).
    static func run(
        _ executableURL: URL,
        _ arguments: [String],
        workingDirectory: URL? = nil
    ) throws -> ShellResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return ShellResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}
