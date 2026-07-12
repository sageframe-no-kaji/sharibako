import Foundation
import Yams

/// Public entry point for reading and writing a Sharibako vault.
///
/// A `VaultCore` value binds to an on-disk vault directory. The AT-01 methods
/// cover the operations that don't require decryption; AT-02 extends the type
/// with age-driven read/write for `.age` files.
public struct VaultCore: Sendable {
    /// Absolute URL of the vault root (the directory containing `shared/` and `scopes/`).
    public let vaultURL: URL

    /// Absolute URL of the age private-key file, if the vault was opened with encryption.
    ///
    /// `nil` when the caller used ``init(vaultURL:)``; encryption operations refuse to
    /// run in that state.
    internal let ageKeyURL: URL?

    /// Cached recipient public key extracted from the age key file at init time.
    internal let publicKey: String?

    /// Creates a fresh vault's directory structure (`scopes/` and `shared/`) at `vaultURL`.
    ///
    /// The public bootstrap entry point: both initializers require an existing vault
    /// directory, so a fresh install must scaffold one first. `key generate` calls
    /// this. Idempotent — succeeds if the directories already exist. Wraps filesystem
    /// failures as `VaultError.fileSystemError`.
    ///
    /// - Parameter vaultURL: Absolute URL of the vault root to scaffold.
    /// - Throws: `VaultError.fileSystemError` if the `scopes/` or `shared/` directory
    ///   cannot be created.
    public static func createVault(at vaultURL: URL) throws {
        try VaultLayout.createVaultLayout(at: vaultURL)
    }

    /// Binds to an existing vault directory (no encryption operations available).
    ///
    /// - Parameter vaultURL: Absolute URL of the vault root.
    /// - Throws: `VaultError.vaultNotFound(path:)` if the directory does not exist.
    ///   Does not create the vault; call ``createVault(at:)`` first when
    ///   initializing a fresh vault.
    public init(vaultURL: URL) throws {
        try Self.assertVaultDirectoryExists(vaultURL)
        self.vaultURL = vaultURL
        self.ageKeyURL = nil
        self.publicKey = nil
    }

    /// Binds to an existing vault directory with an age identity for encryption.
    ///
    /// Reads the age private-key file to extract and cache the recipient public key
    /// so subsequent encryption calls don't re-parse it. The private-key file
    /// itself is not validated further at init time — a corrupt or missing key
    /// surfaces as `VaultError.ageInvocationFailed` on first encrypt or decrypt.
    ///
    /// - Parameters:
    ///   - vaultURL: Absolute URL of the vault root.
    ///   - ageKeyURL: Absolute URL of the age private-key file (as produced by `age-keygen`).
    /// - Throws: `VaultError.vaultNotFound(path:)` if the vault directory is missing;
    ///   `VaultError.fileSystemError` if the age key file cannot be read;
    ///   `VaultError.ageInvocationFailed` if the public-key header line is not found.
    public init(vaultURL: URL, ageKeyURL: URL) throws {
        try Self.assertVaultDirectoryExists(vaultURL)
        self.vaultURL = vaultURL
        self.ageKeyURL = ageKeyURL
        self.publicKey = try Self.extractPublicKey(from: ageKeyURL)
    }

    private static func assertVaultDirectoryExists(_ vaultURL: URL) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: vaultURL.path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            throw VaultError.vaultNotFound(path: vaultURL)
        }
    }

    private static func extractPublicKey(from ageKeyURL: URL) throws -> String {
        let contents: String
        do {
            contents = try String(contentsOf: ageKeyURL, encoding: .utf8)
        } catch {
            throw VaultError.fileSystemError(path: ageKeyURL, underlying: error)
        }
        let prefix = "# public key: "
        for line in contents.split(whereSeparator: \.isNewline) where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        throw VaultError.ageInvocationFailed(
            exitCode: -1,
            stderr: "age key at \(ageKeyURL.path) has no '# public key:' header line"
        )
    }

    /// Lists every scope in the vault, sorted by identity.
    ///
    /// A subdirectory of `scopes/` counts as a scope only if it contains a readable
    /// `scope.yaml`. Directories without one are silently skipped so partial writes
    /// during development don't crash surface-level enumeration.
    public func listScopes() throws -> [ScopeMetadata] {
        let scopesRoot = VaultLayout.scopesDirectoryURL(in: vaultURL)
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: scopesRoot.path) {
            return []
        }

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: scopesRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw VaultError.fileSystemError(path: scopesRoot, underlying: error)
        }

        var scopes: [ScopeMetadata] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            // Skip, don't throw: one stray out-of-grammar directory must not
            // brick every listing verb (ho-04.9).
            guard VaultLayout.isValidIdentifier(entry.lastPathComponent) else { continue }
            let yamlURL = try VaultLayout.scopeYAMLURL(entry.lastPathComponent, in: vaultURL)
            guard fileManager.fileExists(atPath: yamlURL.path) else { continue }
            scopes.append(try decodeScopeYAML(at: yamlURL))
        }
        return scopes.sorted { $0.identity < $1.identity }
    }

    /// Lists every shared entry ID, sorted alphabetically.
    ///
    /// Returns the filename stem (without `.age`) of each file in `shared/`.
    public func listShared() throws -> [String] {
        let sharedRoot = VaultLayout.sharedDirectoryURL(in: vaultURL)
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: sharedRoot.path) {
            return []
        }

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: sharedRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw VaultError.fileSystemError(path: sharedRoot, underlying: error)
        }

        let stems =
            entries
            .filter { $0.pathExtension == "age" }
            .map { $0.deletingPathExtension().lastPathComponent }
            // Skip out-of-grammar stems so a stray file can't surface an ID
            // that every downstream path helper would then reject (ho-04.9).
            .filter { VaultLayout.isValidIdentifier($0) }
        return stems.sorted()
    }

    /// Loads the metadata for a single scope.
    ///
    /// - Parameter id: Scope identifier (matches the directory name).
    /// - Returns: The decoded `ScopeMetadata`.
    /// - Throws: `VaultError.scopeNotFound(id:)` if the scope directory or its
    ///   `scope.yaml` is missing; `VaultError.yamlDecodeError` if decoding fails.
    public func getScope(_ id: String) throws -> ScopeMetadata {
        let yamlURL = try VaultLayout.scopeYAMLURL(id, in: vaultURL)
        guard FileManager.default.fileExists(atPath: yamlURL.path) else {
            throw VaultError.scopeNotFound(id: id)
        }
        return try decodeScopeYAML(at: yamlURL)
    }

    /// Creates a new scope directory and its `scope.yaml` metadata file.
    ///
    /// Requires that the scope does not already exist; throws
    /// ``VaultError/scopeAlreadyExists(id:)`` otherwise. Does not encrypt anything,
    /// so no age key is required to create an empty scope.
    ///
    /// - Parameters:
    ///   - id: Scope identifier (becomes the directory name).
    ///   - type: Category driving Workshop grouping and CLI display.
    ///   - displayName: Optional human-friendly display label.
    /// - Throws: ``VaultError/scopeAlreadyExists(id:)`` if the scope directory or its
    ///   `scope.yaml` is already present; ``VaultError/yamlEncodeError(path:underlying:)``
    ///   if metadata encoding fails; ``VaultError/fileSystemError(path:underlying:)``
    ///   for other IO failures.
    public func createScope(
        _ id: String,
        type: ScopeType,
        displayName: String? = nil
    ) throws {
        let scopeDir = try VaultLayout.scopeDirectoryURL(id, in: vaultURL)
        let yamlURL = try VaultLayout.scopeYAMLURL(id, in: vaultURL)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: scopeDir.path) || fileManager.fileExists(atPath: yamlURL.path) {
            throw VaultError.scopeAlreadyExists(id: id)
        }
        do {
            try fileManager.createDirectory(at: scopeDir, withIntermediateDirectories: true)
        } catch {
            throw VaultError.fileSystemError(path: scopeDir, underlying: error)
        }
        let metadata = ScopeMetadata(identity: id, type: type, displayName: displayName)
        let yaml: String
        do {
            yaml = try YAMLEncoder().encode(metadata)
        } catch {
            throw VaultError.yamlEncodeError(path: yamlURL, underlying: error)
        }
        do {
            try yaml.write(to: yamlURL, atomically: true, encoding: .utf8)
        } catch {
            throw VaultError.fileSystemError(path: yamlURL, underlying: error)
        }
    }

    /// Enumerates a scope's secrets without decrypting.
    ///
    /// Returns one `SecretInfo` per `.age` or `.link` file in the scope directory
    /// (`scope.yaml` excluded). Results are sorted by key.
    public func inspect(_ scopeID: String) throws -> [SecretInfo] {
        let scopeDir = try VaultLayout.scopeDirectoryURL(scopeID, in: vaultURL)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: scopeDir.path) else {
            throw VaultError.scopeNotFound(id: scopeID)
        }

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: scopeDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw VaultError.fileSystemError(path: scopeDir, underlying: error)
        }

        var infos: [SecretInfo] = []
        for entry in entries {
            let key = entry.deletingPathExtension().lastPathComponent
            // Skip out-of-grammar stems: surfacing them as keys would only
            // set up a downstream invalidIdentifier throw (ho-04.9).
            guard VaultLayout.isValidIdentifier(key) else { continue }
            switch entry.pathExtension {
            case "age":
                infos.append(SecretInfo(key: key, kind: .value))
            case "link":
                let sharedID = try readLinkTarget(at: entry)
                infos.append(SecretInfo(key: key, kind: .link(sharedID: sharedID)))
            default:
                continue
            }
        }
        return infos.sorted { $0.key < $1.key }
    }

    /// Creates a link from a scope key to a shared entry.
    ///
    /// Writes `<key>.link` containing the shared entry ID and removes any
    /// pre-existing `<key>.age` for the same key (a scope key is either a
    /// direct value or a link, never both). The shared entry must exist
    /// (ho-04.10, superseding ho-01's dangling-link permissiveness): a dangling
    /// link only ever bricks reads of the key until the target appears.
    ///
    /// - Throws: `VaultError.scopeNotFound(id:)` if the scope directory is absent;
    ///   `VaultError.sharedEntryNotFound(id:)` if the shared entry does not exist.
    public func link(_ key: String, inScope scopeID: String, toShared sharedID: String) throws {
        // The sharedID becomes a .link payload — the write side of the
        // contract readLinkTarget enforces on the read side (ho-04.9).
        try VaultLayout.validateIdentifier(sharedID, as: .sharedEntry)
        let scopeDir = try VaultLayout.scopeDirectoryURL(scopeID, in: vaultURL)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: scopeDir.path) else {
            throw VaultError.scopeNotFound(id: scopeID)
        }
        let sharedURL = try VaultLayout.sharedEntryURL(sharedID, in: vaultURL)
        guard fileManager.fileExists(atPath: sharedURL.path) else {
            throw VaultError.sharedEntryNotFound(id: sharedID)
        }

        let linkURL = try VaultLayout.linkURL(key, inScope: scopeID, in: vaultURL)
        do {
            try sharedID.write(to: linkURL, atomically: true, encoding: .utf8)
        } catch {
            throw VaultError.fileSystemError(path: linkURL, underlying: error)
        }

        let ageURL = try VaultLayout.secretURL(key, inScope: scopeID, in: vaultURL)
        if fileManager.fileExists(atPath: ageURL.path) {
            do {
                try fileManager.removeItem(at: ageURL)
            } catch {
                throw VaultError.fileSystemError(path: ageURL, underlying: error)
            }
        }
    }

    /// Builds the vault-wide link graph: shared entry ID → referencing (scope, key) pairs.
    ///
    /// Walks every `scopes/*/*.link` file. Shared entries with no `.link` references
    /// simply don't appear as keys in the returned dictionary.
    public func linkGraph() throws -> [String: [(scopeID: String, key: String)]] {
        let scopesRoot = VaultLayout.scopesDirectoryURL(in: vaultURL)
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: scopesRoot.path) {
            return [:]
        }

        let scopeDirs: [URL]
        do {
            scopeDirs = try fileManager.contentsOfDirectory(
                at: scopesRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw VaultError.fileSystemError(path: scopesRoot, underlying: error)
        }

        var graph: [String: [(scopeID: String, key: String)]] = [:]
        for scopeDir in scopeDirs {
            let values = try? scopeDir.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            let scopeID = scopeDir.lastPathComponent
            // Same skip-don't-throw posture as listScopes (ho-04.9).
            guard VaultLayout.isValidIdentifier(scopeID) else { continue }

            let entries: [URL]
            do {
                entries = try fileManager.contentsOfDirectory(
                    at: scopeDir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
            } catch {
                throw VaultError.fileSystemError(path: scopeDir, underlying: error)
            }

            for entry in entries where entry.pathExtension == "link" {
                let key = entry.deletingPathExtension().lastPathComponent
                guard VaultLayout.isValidIdentifier(key) else { continue }
                let sharedID = try readLinkTarget(at: entry)
                graph[sharedID, default: []].append((scopeID: scopeID, key: key))
            }
        }
        return graph
    }

    /// Returns shared entry IDs that no scope links to, sorted alphabetically.
    ///
    /// Useful for cleanup surfaces: a shared entry that no `.link` file references
    /// is a candidate for removal.
    public func orphanedSharedEntries() throws -> [String] {
        let shared = try listShared()
        let referenced = Set(try linkGraph().keys)
        return shared.filter { !referenced.contains($0) }.sorted()
    }

    // MARK: - Deletion (ho-06.7)

    /// Deletes a scope and everything in it.
    ///
    /// Removes `scopes/<id>/` and its whole contents — `scope.yaml`, every
    /// `<KEY>.age`, every `<KEY>.link`. A scope's own `.link` files are pointers;
    /// they vanish with the scope and nothing in `shared/` is touched. Requires no
    /// age key — deletion removes files, it does not decrypt them.
    ///
    /// Deletion only ever touches the vault (system design §): `.sharibako`
    /// markers on disk and already-materialized `.env` files are left in place,
    /// and the removal is not committed — a later `sync` commits it.
    ///
    /// - Parameter id: Scope identifier (the directory name).
    /// - Throws: ``VaultError/invalidIdentifier(kind:value:source:)`` for an
    ///   out-of-grammar ID; ``VaultError/scopeNotFound(id:)`` if the scope
    ///   directory is absent; ``VaultError/fileSystemError(path:underlying:)`` if
    ///   removal fails.
    public func deleteScope(_ id: String) throws {
        let scopeDir = try VaultLayout.scopeDirectoryURL(id, in: vaultURL)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: scopeDir.path) else {
            throw VaultError.scopeNotFound(id: id)
        }
        do {
            try fileManager.removeItem(at: scopeDir)
        } catch {
            throw VaultError.fileSystemError(path: scopeDir, underlying: error)
        }
    }

    /// Deletes a shared entry, refusing when scopes still link to it.
    ///
    /// Removes `shared/<id>.age`. Because other scopes may point `.link` files at
    /// this entry, deletion is guarded: if any scope links it and `force` is
    /// `false`, this throws ``VaultError/sharedEntryLinked(id:linkers:)`` naming
    /// every referencing `(scope, key)` pair and removes nothing — the caller
    /// `unlink`s first (which preserves the value locally) and retries. With
    /// `force == true`, the entry is removed and the linkers are left as dangling
    /// `.link` files, surfaced by the existing orphan/heal machinery
    /// (``VaultError/linkTargetMissing(id:)`` on the next resolution). Requires no
    /// age key.
    ///
    /// Like ``deleteScope(_:)``, this only touches the vault and is not committed.
    ///
    /// - Parameters:
    ///   - id: Shared-entry identifier (the `shared/<id>.age` stem).
    ///   - force: When `true`, delete even if linked, orphaning the linkers.
    /// - Throws: ``VaultError/invalidIdentifier(kind:value:source:)`` for an
    ///   out-of-grammar ID; ``VaultError/sharedEntryNotFound(id:)`` if absent;
    ///   ``VaultError/sharedEntryLinked(id:linkers:)`` if linked and not forced;
    ///   ``VaultError/fileSystemError(path:underlying:)`` if removal fails.
    public func deleteSharedEntry(_ id: String, force: Bool = false) throws {
        let sharedURL = try VaultLayout.sharedEntryURL(id, in: vaultURL)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sharedURL.path) else {
            throw VaultError.sharedEntryNotFound(id: id)
        }
        if !force {
            let linkers = try linkGraph()[id] ?? []
            if !linkers.isEmpty {
                throw VaultError.sharedEntryLinked(id: id, linkers: linkers)
            }
        }
        do {
            try fileManager.removeItem(at: sharedURL)
        } catch {
            throw VaultError.fileSystemError(path: sharedURL, underlying: error)
        }
    }

    // MARK: - Identifier grammar (public gateway)

    /// Whether `value` satisfies the vault identifier grammar
    /// `^[A-Za-z0-9_][A-Za-z0-9._-]*$` (ho-04.9).
    ///
    /// Surfaces (CLI/GUI) use this for early, prompt-friendly validation;
    /// the library enforces the same grammar internally at the path-building
    /// chokepoint regardless.
    public static func isValidIdentifier(_ value: String) -> Bool {
        VaultLayout.isValidIdentifier(value)
    }

    // MARK: - Private helpers

    /// Decodes a scope's YAML file into `ScopeMetadata`, mapping errors to `VaultError`.
    private func decodeScopeYAML(at url: URL) throws -> ScopeMetadata {
        let contents: String
        do {
            contents = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw VaultError.fileSystemError(path: url, underlying: error)
        }
        do {
            return try YAMLDecoder().decode(ScopeMetadata.self, from: contents)
        } catch {
            throw VaultError.yamlDecodeError(path: url, underlying: error)
        }
    }

    /// Reads a `.link` file's shared-entry-ID payload, trimming surrounding whitespace.
    ///
    /// Shared with the encryption extension so `unlink` and `getValue` can resolve
    /// the same link format without duplicating the parser.
    ///
    /// `.link` files sync via git from other machines — the payload is
    /// untrusted input that becomes a path component. It must satisfy the
    /// identifier grammar; a tampered payload (`../../…`) would otherwise
    /// direct `age` to decrypt — or `rotateShared` to overwrite — an
    /// arbitrary vault-external path (ho-04.9).
    ///
    /// - Throws: ``VaultError/invalidIdentifier(kind:value:source:)`` with the
    ///   link file as `source` for an out-of-grammar payload.
    internal func readLinkTarget(at url: URL) throws -> String {
        let raw: String
        do {
            raw = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw VaultError.fileSystemError(path: url, underlying: error)
        }
        let payload = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        try VaultLayout.validateIdentifier(payload, as: .sharedEntry, source: url)
        return payload
    }
}
