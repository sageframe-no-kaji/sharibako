import Foundation

/// Destructive verbs: delete a scope, a shared entry, or a single secret (ho-06.7).
///
/// Split out of `VaultCore.swift` to keep that type's body under SwiftLint's
/// `type_body_length` ceiling — a mechanical reorganization following the
/// `VaultCore+Encryption.swift` precedent, not a change in ownership. Every verb
/// here is filesystem-only: deletion removes files, it never decrypts, so these
/// are reachable through the keyless `init(vaultURL:)` and require no age key and
/// no Touch ID. Deletion only ever touches the vault (system design §); `.sharibako`
/// markers and already-materialized `.env` files are left in place, and no
/// removal is committed — a later `sync` commits it.
extension VaultCore {
    /// Deletes a scope and everything in it.
    ///
    /// Removes `scopes/<id>/` and its whole contents — `scope.yaml`, every
    /// `<KEY>.age`, every `<KEY>.link`. A scope's own `.link` files are pointers;
    /// they vanish with the scope and nothing in `shared/` is touched.
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
    /// (``VaultError/linkTargetMissing(id:)`` on the next resolution).
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

    /// Deletes a single secret (a `<key>.age` value or a `<key>.link`) from a scope.
    ///
    /// Removes whichever of the two files backs the key — a scope key is either a
    /// direct value or a link, never both. Deleting a link removes only the
    /// pointer; the shared entry it named is untouched.
    ///
    /// - Parameters:
    ///   - key: The secret key to delete.
    ///   - scopeID: The scope holding it.
    /// - Throws: ``VaultError/invalidIdentifier(kind:value:source:)`` for an
    ///   out-of-grammar identifier; ``VaultError/scopeNotFound(id:)`` if the scope
    ///   directory is absent; ``VaultError/secretNotFound(scope:key:)`` if the key
    ///   has neither an `.age` nor a `.link` file;
    ///   ``VaultError/fileSystemError(path:underlying:)`` if removal fails.
    public func deleteSecret(_ key: String, inScope scopeID: String) throws {
        let scopeDir = try VaultLayout.scopeDirectoryURL(scopeID, in: vaultURL)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: scopeDir.path) else {
            throw VaultError.scopeNotFound(id: scopeID)
        }
        let ageURL = try VaultLayout.secretURL(key, inScope: scopeID, in: vaultURL)
        let linkURL = try VaultLayout.linkURL(key, inScope: scopeID, in: vaultURL)
        let target: URL
        if fileManager.fileExists(atPath: ageURL.path) {
            target = ageURL
        } else if fileManager.fileExists(atPath: linkURL.path) {
            target = linkURL
        } else {
            throw VaultError.secretNotFound(scope: scopeID, key: key)
        }
        do {
            try fileManager.removeItem(at: target)
        } catch {
            throw VaultError.fileSystemError(path: target, underlying: error)
        }
    }
}
