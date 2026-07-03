import Foundation

/// Internal helpers that encode the vault's on-disk URL structure.
///
/// The filesystem is the schema (system design §2). Every URL used to read
/// or write a vault file passes through one of these helpers so the layout
/// exists in exactly one place.
internal enum VaultLayout {
    /// Filename prefix for encrypt-path staging files.
    ///
    /// `encryptAndWrite` stages `age` output as `.sharibako-tmp-<uuid>` in the
    /// destination's own directory (same volume, so the final rename is atomic)
    /// and renames over the real name on success. The prefix is distinctive so
    /// Conduit's `git add -A` can exclude crash leftovers from sync commits —
    /// a leftover is ciphertext-only and deliberately stays VISIBLE in
    /// `git status` rather than being hidden by ignore rules.
    internal static let stagingPrefix = ".sharibako-tmp-"

    /// URL of a staging sibling for an encrypt destination, unique per call.
    internal static func stagingURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent("\(stagingPrefix)\(UUID().uuidString)", isDirectory: false)
    }

    // MARK: - Identifier grammar (ho-04.9)

    /// First character: ASCII alphanumeric or underscore.
    ///
    /// Excluding `.` here makes `.`/`..`, hidden-file names, and the
    /// ``stagingPrefix`` all structurally impossible — no special-case checks.
    private static let identifierFirst = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_"
    )
    /// Remaining characters add `.` and `-` to ``identifierFirst``.
    ///
    /// The alphabet contains no `/`, so a valid identifier is always a
    /// single path component.
    private static let identifierRest = identifierFirst.union(CharacterSet(charactersIn: ".-"))

    /// Whether `value` conforms to the identifier grammar
    /// `^[A-Za-z0-9_][A-Za-z0-9._-]*$`.
    ///
    /// Scope IDs, keys, shared-entry IDs, and `.link` payloads all use this
    /// one grammar. These strings sync via git from other machines and become
    /// path components; the grammar is the traversal guard, not a style rule.
    internal static func isValidIdentifier(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first, identifierFirst.contains(first) else {
            return false
        }
        return value.unicodeScalars.dropFirst().allSatisfy { identifierRest.contains($0) }
    }

    /// Throws ``VaultError/invalidIdentifier(kind:value:source:)`` unless
    /// `value` conforms to the identifier grammar.
    internal static func validateIdentifier(
        _ value: String,
        as kind: IdentifierKind,
        source: URL? = nil
    ) throws {
        guard isValidIdentifier(value) else {
            throw VaultError.invalidIdentifier(kind: kind, value: value, source: source)
        }
    }

    // MARK: - URL helpers

    /// URL of the vault's `shared/` directory.
    internal static func sharedDirectoryURL(in vault: URL) -> URL {
        vault.appendingPathComponent("shared", isDirectory: true)
    }

    /// URL of the vault's `scopes/` directory.
    internal static func scopesDirectoryURL(in vault: URL) -> URL {
        vault.appendingPathComponent("scopes", isDirectory: true)
    }

    /// URL of a specific scope's directory: `scopes/<id>/`.
    ///
    /// Throws ``VaultError/invalidIdentifier(kind:value:source:)`` for an
    /// out-of-grammar ID — every ID-taking helper validates before the ID
    /// becomes a path component, making this type the traversal chokepoint.
    internal static func scopeDirectoryURL(_ id: String, in vault: URL) throws -> URL {
        try validateIdentifier(id, as: .scope)
        return scopesDirectoryURL(in: vault).appendingPathComponent(id, isDirectory: true)
    }

    /// URL of a scope's `scope.yaml` metadata file.
    internal static func scopeYAMLURL(_ id: String, in vault: URL) throws -> URL {
        try scopeDirectoryURL(id, in: vault).appendingPathComponent("scope.yaml", isDirectory: false)
    }

    /// URL of a scope-local encrypted secret: `scopes/<scopeID>/<key>.age`.
    internal static func secretURL(_ key: String, inScope scopeID: String, in vault: URL) throws -> URL {
        try validateIdentifier(key, as: .key)
        return try scopeDirectoryURL(scopeID, in: vault)
            .appendingPathComponent("\(key).age", isDirectory: false)
    }

    /// URL of a link file: `scopes/<scopeID>/<key>.link`.
    internal static func linkURL(_ key: String, inScope scopeID: String, in vault: URL) throws -> URL {
        try validateIdentifier(key, as: .key)
        return try scopeDirectoryURL(scopeID, in: vault)
            .appendingPathComponent("\(key).link", isDirectory: false)
    }

    /// URL of a shared encrypted entry: `shared/<id>.age`.
    internal static func sharedEntryURL(_ id: String, in vault: URL) throws -> URL {
        try validateIdentifier(id, as: .sharedEntry)
        return sharedDirectoryURL(in: vault).appendingPathComponent("\(id).age", isDirectory: false)
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
