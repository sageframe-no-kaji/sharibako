import Foundation

/// Internal helpers that encode the vault's on-disk URL structure.
///
/// The filesystem is the schema (system design §2). Every URL used to read
/// or write a vault file passes through one of these helpers so the layout
/// exists in exactly one place.
internal enum VaultLayout {
    /// URL of the vault's `shared/` directory.
    internal static func sharedDirectoryURL(in vault: URL) -> URL {
        vault.appendingPathComponent("shared", isDirectory: true)
    }

    /// URL of the vault's `scopes/` directory.
    internal static func scopesDirectoryURL(in vault: URL) -> URL {
        vault.appendingPathComponent("scopes", isDirectory: true)
    }

    /// URL of a specific scope's directory: `scopes/<id>/`.
    internal static func scopeDirectoryURL(_ id: String, in vault: URL) -> URL {
        scopesDirectoryURL(in: vault).appendingPathComponent(id, isDirectory: true)
    }

    /// URL of a scope's `scope.yaml` metadata file.
    internal static func scopeYAMLURL(_ id: String, in vault: URL) -> URL {
        scopeDirectoryURL(id, in: vault).appendingPathComponent("scope.yaml", isDirectory: false)
    }

    /// URL of a scope-local encrypted secret: `scopes/<scopeID>/<key>.age`.
    internal static func secretURL(_ key: String, inScope scopeID: String, in vault: URL) -> URL {
        scopeDirectoryURL(scopeID, in: vault).appendingPathComponent("\(key).age", isDirectory: false)
    }

    /// URL of a link file: `scopes/<scopeID>/<key>.link`.
    internal static func linkURL(_ key: String, inScope scopeID: String, in vault: URL) -> URL {
        scopeDirectoryURL(scopeID, in: vault).appendingPathComponent("\(key).link", isDirectory: false)
    }

    /// URL of a shared encrypted entry: `shared/<id>.age`.
    internal static func sharedEntryURL(_ id: String, in vault: URL) -> URL {
        sharedDirectoryURL(in: vault).appendingPathComponent("\(id).age", isDirectory: false)
    }

    /// Creates a fresh vault's `shared/` and `scopes/` subdirectories.
    ///
    /// Idempotent — succeeds if directories already exist (via
    /// `withIntermediateDirectories: true`). Wraps filesystem failures as
    /// `VaultError.fileSystemError`.
    internal static func createVaultLayout(at vaultURL: URL) throws {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: sharedDirectoryURL(in: vaultURL),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: scopesDirectoryURL(in: vaultURL),
                withIntermediateDirectories: true
            )
        } catch {
            throw VaultError.fileSystemError(path: vaultURL, underlying: error)
        }
    }
}
