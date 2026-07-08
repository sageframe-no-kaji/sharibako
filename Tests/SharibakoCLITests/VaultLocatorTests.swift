import Foundation
import Testing

@testable import SharibakoCLI
@testable import SharibakoCore

@Suite("VaultLocator")
struct VaultLocatorTests {
    /// Creates a temp directory, removed by the caller via the returned URL.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharibako-locator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A home directory guaranteed to have no `.sharibako/vault/` underneath.
    private func makeEmptyHome() throws -> URL {
        try makeTempDir()
    }

    // MARK: - resolve: --vault flag

    @Test("resolve returns the --vault flag path when it is a directory")
    func resolveFlagValid() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resolved = try VaultLocator.resolve(globalFlag: dir, environment: [:])
        #expect(resolved.path == dir.path)
    }

    @Test("resolve throws vaultNotFound when the --vault flag path does not exist")
    func resolveFlagMissing() throws {
        let ghost = URL(fileURLWithPath: "/nonexistent/sharibako-vault-\(UUID().uuidString)")
        let error = #expect(throws: VaultError.self) {
            _ = try VaultLocator.resolve(globalFlag: ghost, environment: [:])
        }
        guard case .vaultNotFound(let path) = error else {
            Issue.record("expected vaultNotFound, got \(String(describing: error))")
            return
        }
        #expect(path.path == ghost.path)
    }

    @Test("resolve throws vaultNotFound when the --vault flag points at a file")
    func resolveFlagIsFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("not-a-dir.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: VaultError.self) {
            _ = try VaultLocator.resolve(globalFlag: file, environment: [:])
        }
    }

    // MARK: - resolve: SHARIBAKO_VAULT env

    @Test("resolve falls back to SHARIBAKO_VAULT when no flag is supplied")
    func resolveEnvValid() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resolved = try VaultLocator.resolve(
            globalFlag: nil, environment: ["SHARIBAKO_VAULT": dir.path])
        #expect(resolved.path == dir.path)
    }

    @Test("resolve throws vaultNotFound when SHARIBAKO_VAULT points nowhere")
    func resolveEnvMissing() throws {
        let ghost = "/nonexistent/sharibako-env-\(UUID().uuidString)"
        let error = #expect(throws: VaultError.self) {
            _ = try VaultLocator.resolve(
                globalFlag: nil, environment: ["SHARIBAKO_VAULT": ghost])
        }
        guard case .vaultNotFound(let path) = error else {
            Issue.record("expected vaultNotFound, got \(String(describing: error))")
            return
        }
        #expect(path.path == ghost)
    }

    // MARK: - resolve: ~/.sharibako/vault default

    @Test("resolve falls back to ~/.sharibako/vault when no flag or env is set")
    func resolveDefaultValid() throws {
        let home = try makeEmptyHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let vaultDir =
            home
            .appendingPathComponent(".sharibako")
            .appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)
        let resolved = try VaultLocator.resolve(globalFlag: nil, environment: [:], home: home)
        #expect(resolved.path == vaultDir.path)
    }

    @Test("resolve throws vaultNotFound naming the default path when nothing exists")
    func resolveDefaultMissing() throws {
        let home = try makeEmptyHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let error = #expect(throws: VaultError.self) {
            _ = try VaultLocator.resolve(globalFlag: nil, environment: [:], home: home)
        }
        guard case .vaultNotFound(let path) = error else {
            Issue.record("expected vaultNotFound, got \(String(describing: error))")
            return
        }
        #expect(path.path.hasSuffix(".sharibako/vault"))
    }

    // MARK: - intendedVaultURL (creation path — no existence check)

    @Test("intendedVaultURL returns the --vault flag path without checking existence")
    func intendedFlagNoExistenceCheck() {
        let ghost = URL(fileURLWithPath: "/nonexistent/sharibako-\(UUID().uuidString)")
        let url = VaultLocator.intendedVaultURL(globalFlag: ghost, environment: [:])
        #expect(url.path == ghost.path)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("intendedVaultURL falls back to SHARIBAKO_VAULT without checking existence")
    func intendedEnvNoExistenceCheck() {
        let ghost = "/nonexistent/sharibako-env-\(UUID().uuidString)"
        let url = VaultLocator.intendedVaultURL(
            globalFlag: nil, environment: ["SHARIBAKO_VAULT": ghost])
        #expect(url.path == ghost)
    }

    @Test("intendedVaultURL falls back to ~/.sharibako/vault without requiring it to exist")
    func intendedDefaultNoExistenceCheck() throws {
        let home = try makeEmptyHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = VaultLocator.intendedVaultURL(globalFlag: nil, environment: [:], home: home)
        #expect(url.path.hasSuffix(".sharibako/vault"))
        // The fresh-install case: the default path does not exist yet, and no throw.
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - resolveAgeKey

    @Test("resolveAgeKey prefers the --age-key flag")
    func resolveAgeKeyFlag() {
        let flag = URL(fileURLWithPath: "/keys/from-flag.txt")
        let resolved = VaultLocator.resolveAgeKey(
            globalFlag: flag, environment: ["SHARIBAKO_AGE_KEY": "/keys/from-env.txt"])
        #expect(resolved?.path == flag.path)
    }

    @Test("resolveAgeKey falls back to SHARIBAKO_AGE_KEY")
    func resolveAgeKeyEnv() {
        let resolved = VaultLocator.resolveAgeKey(
            globalFlag: nil, environment: ["SHARIBAKO_AGE_KEY": "/keys/from-env.txt"])
        #expect(resolved?.path == "/keys/from-env.txt")
    }

    @Test("resolveAgeKey returns nil when neither flag nor env is set")
    func resolveAgeKeyNone() {
        #expect(VaultLocator.resolveAgeKey(globalFlag: nil, environment: [:]) == nil)
    }

    // MARK: - resolveProvider

    @Test("resolveProvider builds a FileAgeKeyProvider when a path is configured")
    func resolveProviderFile() {
        let flag = URL(fileURLWithPath: "/keys/key.txt")
        let provider = VaultLocator.resolveProvider(globalFlag: flag, environment: [:])
        #expect(provider is FileAgeKeyProvider)
    }

    #if os(macOS)
        @Test("resolveProvider falls back to the Keychain provider when no path is configured")
        func resolveProviderKeychain() {
            let provider = VaultLocator.resolveProvider(globalFlag: nil, environment: [:])
            #expect(provider is KeychainAgeKeyProvider)
        }
    #endif
}
