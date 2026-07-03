import Foundation
import Testing

@testable import SharibakoCore

/// Filesystem error-path tests for `VaultCore`.
///
/// Covers defensive catch blocks that surface when the vault's filesystem
/// layout becomes unreadable or unwritable — paths that normal happy-path
/// tests can't reach without engineering a specific filesystem failure.
///
/// Uses `FileManager.setAttributes` with POSIX permissions to reproduce
/// unreadable-directory and unreadable-file conditions; each test restores
/// permissions in a `defer` block so temp-dir teardown succeeds.
@Suite("VaultCore Filesystem Errors")
struct VaultCoreFilesystemErrorTests {
    // MARK: - listScopes error paths

    @Test("listScopes throws fileSystemError when the scopes directory is unreadable")
    func listScopesThrowsWhenScopesDirUnreadable() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            let scopesRoot = VaultLayout.scopesDirectoryURL(in: vault)
            let fileManager = FileManager.default
            // Remove read+execute so contentsOfDirectory fails, hitting the
            // fileSystemError catch block in listScopes (line 101 of VaultCore.swift).
            try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: scopesRoot.path)
            defer {
                try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scopesRoot.path)
            }
            let core = try VaultCore(vaultURL: vault)
            #expect(throws: VaultError.self) {
                _ = try core.listScopes()
            }
        }
    }

    @Test("listScopes throws fileSystemError when a scope.yaml is unreadable")
    func listScopesThrowsWhenScopeYAMLUnreadable() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let yamlURL = try VaultLayout.scopeYAMLURL("kanyo-dev", in: vault)
            let fileManager = FileManager.default
            // Remove all permissions so String(contentsOf:) throws, hitting the
            // fileSystemError catch block in decodeScopeYAML (line 294 of VaultCore.swift).
            try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: yamlURL.path)
            defer {
                try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: yamlURL.path)
            }
            let core = try VaultCore(vaultURL: vault)
            #expect(throws: VaultError.self) {
                _ = try core.listScopes()
            }
        }
    }

    // MARK: - listShared error paths

    @Test("listShared throws fileSystemError when the shared directory is unreadable")
    func listSharedThrowsWhenSharedDirUnreadable() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            let sharedRoot = VaultLayout.sharedDirectoryURL(in: vault)
            let fileManager = FileManager.default
            // Remove read+execute so contentsOfDirectory fails, hitting the
            // fileSystemError catch block in listShared (line 134 of VaultCore.swift).
            try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sharedRoot.path)
            defer {
                try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sharedRoot.path)
            }
            let core = try VaultCore(vaultURL: vault)
            #expect(throws: VaultError.self) {
                _ = try core.listShared()
            }
        }
    }

    // MARK: - inspect error paths

    @Test("inspect throws fileSystemError when a .link file is unreadable")
    func inspectThrowsWhenLinkFileUnreadable() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            // Write a .link file and make it unreadable — readLinkTarget's String(contentsOf:)
            // then throws, surfacing as fileSystemError (line 312 of VaultCore.swift).
            let linkURL = try VaultLayout.linkURL("GHOST_KEY", inScope: "kanyo-dev", in: vault)
            try "some-shared-id".write(to: linkURL, atomically: true, encoding: .utf8)
            let fileManager = FileManager.default
            try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: linkURL.path)
            defer {
                try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: linkURL.path)
            }
            let core = try VaultCore(vaultURL: vault)
            #expect(throws: VaultError.self) {
                _ = try core.inspect("kanyo-dev")
            }
        }
    }
}
