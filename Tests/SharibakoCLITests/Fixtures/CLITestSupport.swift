import ArgumentParser
import Foundation
import Testing

@testable import SharibakoCLI
@testable import SharibakoCore

/// Shared fixture helpers for `SharibakoCLITests`.
///
/// Mirrors `VaultTestSupport` from the Core test suite, adding the age-key and
/// command invocation layers that CLI tests need.
enum CLITestSupport {
    /// Creates a temp vault, generates an age key file, and hands both to `body`.
    ///
    /// `body` receives:
    /// - `vaultURL`: an initialised vault directory
    /// - `keyURL`: an age private-key file whose `FileAgeKeyProvider` can be used in tests
    ///
    /// Both are removed after `body` returns, even if it throws.
    static func withEphemeralVaultAndFileKey(
        _ body: (URL, URL) throws -> Void
    ) throws {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharibako-cli-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }
        try VaultLayout.createVaultLayout(at: vault)

        // Generate a real age key for tests that decrypt.
        let keyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharibako-cli-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: keyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: keyDir) }

        let keyURL = keyDir.appendingPathComponent("age-key.txt")
        let ageKeygen = try Shell.findExecutable("age-keygen")
        let result = try Shell.run(ageKeygen, ["-o", keyURL.path])
        guard result.exitCode == 0 else {
            struct SetupFailed: Error {}
            throw SetupFailed()
        }

        try body(vault, keyURL)
    }

    /// Invokes a parsed command's `run()` method in-process.
    ///
    /// Parses `args` via `SharibakoCommand.parseAsRoot(_:)` and calls `run()` on the
    /// result. Async commands are dispatched with `await`. Errors propagate as thrown.
    ///
    /// Note: this calls the command's `run()` directly — it does NOT invoke
    /// `SharibakoCommand.main()`, so `Foundation.exit()` is never called.
    static func runCommand(_ args: [String]) async throws {
        var command = try SharibakoCommand.parseAsRoot(args)
        if var asyncCommand = command as? (any AsyncParsableCommand) {
            try await asyncCommand.run()
        } else {
            try command.run()
        }
    }

    /// Same setup as the synchronous overload; use this variant in `async` tests.
    static func withEphemeralVaultAndFileKeyAsync(
        _ body: (URL, URL) async throws -> Void
    ) async throws {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharibako-cli-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }
        try VaultLayout.createVaultLayout(at: vault)

        let keyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharibako-cli-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: keyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: keyDir) }

        let keyURL = keyDir.appendingPathComponent("age-key.txt")
        let ageKeygen = try Shell.findExecutable("age-keygen")
        let result = try Shell.run(ageKeygen, ["-o", keyURL.path])
        guard result.exitCode == 0 else {
            struct SetupFailed: Error {}
            throw SetupFailed()
        }

        try await body(vault, keyURL)
    }

    /// Sets up a bare-remote git repo plus one vault pointed at it.
    ///
    /// After setup, `vault` has an initial commit pushed to the bare remote.
    /// Both directories are removed when `body` returns.
    static func withEphemeralGitVaultAndRemote(
        _ body: (URL, URL, URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharibako-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let remoteGit = root.appendingPathComponent("remote.git")
        let vaultURL = root.appendingPathComponent("vault")

        let git = try Shell.findExecutable("git")
        let bareResult = try Shell.run(
            git,
            ["init", "--bare", "--initial-branch=main", remoteGit.path]
        )
        guard bareResult.exitCode == 0 else {
            throw VaultError.gitInvocationFailed(exitCode: bareResult.exitCode, stderr: bareResult.stderr)
        }

        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        try VaultLayout.createVaultLayout(at: vaultURL)
        let conduit = try Conduit(vaultURL: vaultURL)
        try conduit.initializeRepository()
        _ = try Shell.run(git, ["checkout", "-b", "main"], workingDirectory: vaultURL)
        try conduit.setIdentity(name: "Sharibako Tests", email: "tests@example.invalid")
        try conduit.setRemote(remoteGit.path)

        let placeholder = vaultURL.appendingPathComponent(".gitkeep")
        try "".write(to: placeholder, atomically: true, encoding: .utf8)
        _ = try conduit.commit(message: "Initial vault setup")
        _ = try conduit.push()

        let keyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharibako-cli-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: keyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: keyDir) }
        let keyURL = keyDir.appendingPathComponent("age-key.txt")
        let ageKeygen = try Shell.findExecutable("age-keygen")
        let keyResult = try Shell.run(ageKeygen, ["-o", keyURL.path])
        guard keyResult.exitCode == 0 else {
            struct SetupFailed: Error {}
            throw SetupFailed()
        }

        try body(vaultURL, remoteGit, keyURL)
    }

    /// Collects `RunFeedback` lines for assertions.
    ///
    /// `@unchecked Sendable` with a lock: the startup line emits synchronously on the
    /// calling thread, but the sink type is `Sendable` and could be handed to background
    /// plumbing, so guard the buffer.
    final class FeedbackCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        /// The captured lines, with their trailing newlines stripped.
        var lines: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage.map { $0.hasSuffix("\n") ? String($0.dropLast()) : $0 }
        }

        /// A sink that appends every emitted line to this collector.
        func sink() -> RunFeedback {
            RunFeedback { [self] line in
                lock.lock()
                storage.append(line)
                lock.unlock()
            }
        }
    }

    /// Writes a minimal scope directory and `scope.yaml` into `vault`.
    static func writeScope(
        _ id: String,
        type: ScopeType = .projectDev,
        in vault: URL
    ) throws {
        let scopeDir = VaultLayout.scopeDirectoryURL(id, in: vault)
        try FileManager.default.createDirectory(at: scopeDir, withIntermediateDirectories: true)
        let yaml = "identity: \(id)\ntype: \(type.rawValue)\n"
        try yaml.write(
            to: VaultLayout.scopeYAMLURL(id, in: vault),
            atomically: true,
            encoding: .utf8
        )
    }
}
