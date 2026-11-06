import Foundation
import Testing

@testable import SharibakoCore

/// Filesystem failure-arm tests for `VaultCore`.
///
/// The `catch` blocks that translate a POSIX refusal into
/// `VaultError.fileSystemError`.
///
/// Provoked by removing the write or read bit from a directory inside an
/// ephemeral temp vault, which is what a vault on a read-only volume, a
/// permissions-mangled sync folder, or another user's directory looks like from
/// the inside. Every test restores the mode before the fixture tears down, so
/// nothing leaks a locked directory into the temp dir.
@Suite("VaultCore filesystem failures")
struct VaultCoreFilesystemFailureTests {
    /// Runs `body` with `url` set to `mode`, restoring `0o755` afterwards.
    private func withMode(_ mode: Int, at url: URL, _ body: () throws -> Void) throws {
        let fileManager = FileManager.default
        try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try body()
    }

    /// Asserts `error` is a `fileSystemError` naming `path`.
    private func expectFileSystemError(_ error: VaultError?, at path: URL) {
        guard case .fileSystemError(let reported, _) = error else {
            Issue.record("expected fileSystemError, got \(String(describing: error))")
            return
        }
        #expect(reported.lastPathComponent == path.lastPathComponent)
    }

    // MARK: - createScope

    @Test("createScope reports a filesystem error when scopes/ is not writable")
    func createScopeIntoReadOnlyScopesRoot() throws {
        try VaultTestSupport.withEphemeralVault { vaultURL in
            let scopesRoot = vaultURL.appendingPathComponent("scopes")
            let vault = try VaultCore(vaultURL: vaultURL)

            try withMode(0o500, at: scopesRoot) {
                let error = #expect(throws: VaultError.self) {
                    try vault.createScope("blocked", type: .other)
                }
                expectFileSystemError(error, at: scopesRoot.appendingPathComponent("blocked"))
            }
        }
    }

    // MARK: - inspect

    @Test("inspect reports a filesystem error when the scope directory is unreadable")
    func inspectUnreadableScope() throws {
        try VaultTestSupport.withEphemeralVault { vaultURL in
            let vault = try VaultCore(vaultURL: vaultURL)
            try vault.createScope("locked", type: .other)
            let scopeDir = vaultURL.appendingPathComponent("scopes/locked")

            try withMode(0o000, at: scopeDir) {
                let error = #expect(throws: VaultError.self) { try vault.inspect("locked") }
                expectFileSystemError(error, at: scopeDir)
            }
        }
    }

    // MARK: - linkGraph

    @Test("linkGraph reports a filesystem error when scopes/ is unreadable")
    func linkGraphUnreadableScopesRoot() throws {
        try VaultTestSupport.withEphemeralVault { vaultURL in
            let scopesRoot = vaultURL.appendingPathComponent("scopes")
            let vault = try VaultCore(vaultURL: vaultURL)

            try withMode(0o000, at: scopesRoot) {
                let error = #expect(throws: VaultError.self) { try vault.linkGraph() }
                expectFileSystemError(error, at: scopesRoot)
            }
        }
    }

    @Test("linkGraph reports a filesystem error when one scope directory is unreadable")
    func linkGraphUnreadableScopeDirectory() throws {
        try VaultTestSupport.withEphemeralVault { vaultURL in
            let vault = try VaultCore(vaultURL: vaultURL)
            try vault.createScope("locked", type: .other)
            let scopeDir = vaultURL.appendingPathComponent("scopes/locked")

            try withMode(0o000, at: scopeDir) {
                let error = #expect(throws: VaultError.self) { try vault.linkGraph() }
                expectFileSystemError(error, at: scopeDir)
            }
        }
    }
}
