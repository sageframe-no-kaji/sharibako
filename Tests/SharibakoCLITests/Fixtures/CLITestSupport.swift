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
