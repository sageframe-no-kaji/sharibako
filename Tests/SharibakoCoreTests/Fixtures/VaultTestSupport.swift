import Foundation

@testable import SharibakoCore

/// Shared fixture helpers for `VaultCore` test suites.
///
/// Housed in an enum namespace so both the filesystem and encryption suites
/// can compose the same seed data without duplicating boilerplate.
enum VaultTestSupport {
    /// Materializes a fresh temp directory + vault layout and calls `body` with the vault URL.
    ///
    /// The directory is removed even if `body` throws.
    static func withEphemeralVault(_ body: (URL) throws -> Void) throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try VaultLayout.createVaultLayout(at: tempDir)
        try body(tempDir)
    }

    /// Materializes a temp vault + age key pair and hands both to `body`.
    ///
    /// Both artifacts are removed after `body` returns (even if it throws).
    static func withEphemeralVaultAndKey(_ body: (URL, AgeKeyFixture) throws -> Void) throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }
        try VaultLayout.createVaultLayout(at: vault)

        let fixture = try AgeKeyFixture.generate()
        defer { try? fixture.cleanup() }

        try body(vault, fixture)
    }

    /// Returns a minimal `scope.yaml` YAML string.
    static func makeScopeYAML(identity: String, type: ScopeType, displayName: String? = nil) -> String {
        var lines = [
            "identity: \(identity)",
            "type: \(type.rawValue)",
        ]
        if let displayName {
            lines.append("display_name: \(displayName)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Creates a scope directory and its `scope.yaml`.
    static func writeScope(
        _ id: String,
        type: ScopeType,
        displayName: String? = nil,
        in vault: URL
    ) throws {
        let scopeDir = VaultLayout.scopeDirectoryURL(id, in: vault)
        try FileManager.default.createDirectory(at: scopeDir, withIntermediateDirectories: true)
        let yaml = makeScopeYAML(identity: id, type: type, displayName: displayName)
        try yaml.write(
            to: VaultLayout.scopeYAMLURL(id, in: vault),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Writes a scope-local `.link` file containing `sharedID`.
    static func writeLink(
        _ key: String,
        inScope scopeID: String,
        sharedID: String,
        in vault: URL
    ) throws {
        let url = VaultLayout.linkURL(key, inScope: scopeID, in: vault)
        try sharedID.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Writes a nonsense byte sequence as a stand-in `<key>.age` (no real encryption).
    ///
    /// AT-01 tests treat `.age` files as opaque and never decrypt them.
    static func writePlaceholderAge(
        _ key: String,
        inScope scopeID: String,
        in vault: URL
    ) throws {
        let url = VaultLayout.secretURL(key, inScope: scopeID, in: vault)
        try Data([0x00, 0x01, 0x02]).write(to: url)
    }

    /// Writes a nonsense byte sequence as a stand-in `shared/<id>.age`.
    static func writeSharedPlaceholderAge(_ id: String, in vault: URL) throws {
        let url = VaultLayout.sharedEntryURL(id, in: vault)
        try Data([0x00]).write(to: url)
    }

    /// Materializes a temp vault, initializes a git repository inside it, and
    /// sets a deterministic test identity before calling `body`.
    ///
    /// - `git init` is called so commit operations work out of the box.
    /// - The committer identity is set to `"Sharibako Tests" / tests@example.invalid`
    ///   so the test suite does not depend on the host machine's git config.
    /// - The vault directory is removed after `body` returns, even if it throws.
    static func withEphemeralGitVault(_ body: (URL) throws -> Void) throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try VaultLayout.createVaultLayout(at: tempDir)
        let conduit = try Conduit(vaultURL: tempDir)
        try conduit.initializeRepository()
        try conduit.setIdentity(name: "Sharibako Tests", email: "tests@example.invalid")
        try body(tempDir)
    }

    /// Encrypts `value` and writes it to a shared entry via a throwaway scope.
    ///
    /// AT-02 needs real ciphertext in `shared/<id>.age` so `getValue` through a
    /// link decrypts. `VaultCore` doesn't expose a "write shared entry" API
    /// directly (v1 flow is `link` then rotate); this helper stages via a
    /// disposable scope, moves the file into `shared/`, and drops the stager.
    static func writeSharedEntry(
        _ sharedID: String,
        value: String,
        notes: String? = nil,
        vault: URL,
        fixture: AgeKeyFixture
    ) throws {
        try writeScope("__stager__", type: .other, in: vault)
        let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
        try core.addSecret("__staged__", value: value, inScope: "__stager__", notes: notes)
        let staged = VaultLayout.secretURL("__staged__", inScope: "__stager__", in: vault)
        let sharedURL = VaultLayout.sharedEntryURL(sharedID, in: vault)
        try FileManager.default.moveItem(at: staged, to: sharedURL)
        try FileManager.default.removeItem(at: VaultLayout.scopeDirectoryURL("__stager__", in: vault))
    }
}
