import Foundation
import Yams

/// Encryption operations for `VaultCore`.
///
/// Kept in a separate file so the AT-01 core stays visually focused and each
/// half of the type body is comfortably within the length linter's ceiling.
extension VaultCore {
    /// Encrypts and writes a new scope-local secret.
    ///
    /// Overwrites any existing `<key>.age` at the same path. Does not delete a
    /// pre-existing `<key>.link` at the same key — call ``unlink(_:inScope:)``
    /// first if the intent is to convert a linked key into a direct value.
    ///
    /// - Parameters:
    ///   - key: Secret key (becomes the filename stem).
    ///   - value: Plaintext value to encrypt.
    ///   - scopeID: Owning scope identifier.
    ///   - notes: Optional freeform notes stored alongside the value.
    /// - Throws: `VaultError.scopeNotFound(id:)` if the scope directory is absent;
    ///   `VaultError.ageInvocationFailed` if `age` exits non-zero;
    ///   `VaultError.shellNotFound(name:)` if no age binary is on PATH;
    ///   `VaultError.yamlEncodeError` if the payload cannot be YAML-encoded.
    public func addSecret(
        _ key: String,
        value: String,
        inScope scopeID: String,
        notes: String? = nil
    ) throws {
        let scopeDir = try VaultLayout.scopeDirectoryURL(scopeID, in: vaultURL)
        guard FileManager.default.fileExists(atPath: scopeDir.path) else {
            throw VaultError.scopeNotFound(id: scopeID)
        }
        let target = try VaultLayout.secretURL(key, inScope: scopeID, in: vaultURL)
        let content = SecretContent(value: value, notes: notes, rotatedAt: Self.todayISODate())
        try encryptAndWrite(content, to: target)
    }

    /// Decrypts and returns the plaintext value for a secret key.
    ///
    /// Resolves `<key>.link` to the shared entry when present; otherwise reads
    /// `<key>.age` directly.
    ///
    /// - Parameters:
    ///   - key: Secret key (filename stem).
    ///   - scopeID: Owning scope identifier.
    /// - Returns: The decrypted `value`.
    /// - Throws: `VaultError.secretNotFound(scope:key:)` if neither a `.age` nor `.link`
    ///   file exists; `VaultError.linkTargetMissing(id:)` if a `.link` points at a
    ///   shared entry that no longer exists; `VaultError.ageInvocationFailed` for
    ///   decryption failures; `VaultError.yamlDecodeError` for a corrupt payload.
    public func getValue(_ key: String, inScope scopeID: String) throws -> String {
        try getSecretContent(key, inScope: scopeID).value
    }

    /// Decrypts and returns the full content (value, notes, rotation date) for a secret key.
    ///
    /// The whole-payload sibling of ``getValue(_:inScope:)`` — same target
    /// resolution (links resolve to their shared entries), same error surface.
    /// The GUI's reveal uses this so notes are displayed alongside the value
    /// instead of being decrypted and discarded.
    ///
    /// - Parameters:
    ///   - key: Secret key (filename stem).
    ///   - scopeID: Owning scope identifier.
    /// - Returns: The decrypted `SecretContent`.
    /// - Throws: The same errors as ``getValue(_:inScope:)``.
    public func getSecretContent(_ key: String, inScope scopeID: String) throws -> SecretContent {
        let target = try resolveSecretTarget(key, inScope: scopeID)
        return try decryptSecretContent(at: target)
    }

    /// Decrypts every owned secret in a scope, resolving links, into a key→value dict.
    ///
    /// Loops ``inspect(_:)`` for the scope's owned keys and calls ``getValue(_:inScope:)``
    /// on each — `.link` files resolve to their shared targets exactly as `getValue` does.
    /// Returns an empty dictionary for a scope with no owned keys. One decrypt per key;
    /// the caller unlocks the age identity once for the whole call.
    ///
    /// This is the bulk-decrypt path `sharibako run` needs (kamae-2.1's `get_all_secrets`).
    /// It reuses the existing single-secret decrypt — no new crypto path.
    ///
    /// - Parameter scopeID: Owning scope identifier.
    /// - Returns: A dictionary mapping each owned key to its decrypted value.
    /// - Throws: `VaultError.scopeNotFound(id:)` if the scope directory is absent;
    ///   `VaultError.linkTargetMissing(id:)` if a `.link` points at a missing shared entry;
    ///   `VaultError.ageInvocationFailed` for decryption failures.
    public func secrets(inScope scopeID: String) throws -> [String: String] {
        let infos = try inspect(scopeID)
        var result: [String: String] = [:]
        for info in infos {
            result[info.key] = try getValue(info.key, inScope: scopeID)
        }
        return result
    }

    /// Updates the notes for a scope-local secret without changing its value or
    /// rotation date.
    ///
    /// Reads the existing `<KEY>.age`, re-encrypts a `SecretContent` with the
    /// **same `value`** and **same `rotatedAt`**, and only the new `notes`. A
    /// notes-only edit is not a rotation and must not bump `rotated_at`; use
    /// ``rotate(_:inScope:newValue:)`` when the value itself changes.
    ///
    /// Only valid for `.value` secrets (i.e., a `<KEY>.age` file exists). A
    /// `.link` file has no local ciphertext; the corresponding `.age` is absent,
    /// so this method throws ``VaultError/secretNotFound(scope:key:)`` for links
    /// and for absent keys alike, mirroring ``rotate(_:inScope:newValue:)``.
    ///
    /// - Parameters:
    ///   - key: Secret key (filename stem).
    ///   - scopeID: Owning scope identifier.
    ///   - notes: New notes string, or `nil` to clear notes.
    /// - Throws: `VaultError.secretNotFound(scope:key:)` if the `.age` is absent;
    ///   `VaultError.ageInvocationFailed` for encrypt/decrypt failures.
    public func updateNotes(_ key: String, inScope scopeID: String, notes: String?) throws {
        let target = try VaultLayout.secretURL(key, inScope: scopeID, in: vaultURL)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw VaultError.secretNotFound(scope: scopeID, key: key)
        }
        let existing = try decryptSecretContent(at: target)
        // Preserve value and rotatedAt; only notes changes.
        let updated = SecretContent(value: existing.value, notes: notes, rotatedAt: existing.rotatedAt)
        try encryptAndWrite(updated, to: target)
    }

    /// Rotates a scope-local secret to a new value, preserving notes.
    ///
    /// Reads the existing `<KEY>.age`, updates `value` and `rotated_at`, and
    /// re-encrypts to the same path.
    ///
    /// - Throws: `VaultError.secretNotFound(scope:key:)` if the `.age` is absent;
    ///   `VaultError.ageInvocationFailed` for encrypt/decrypt failures.
    public func rotate(_ key: String, inScope scopeID: String, newValue: String) throws {
        let target = try VaultLayout.secretURL(key, inScope: scopeID, in: vaultURL)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw VaultError.secretNotFound(scope: scopeID, key: key)
        }
        let existing = try decryptSecretContent(at: target)
        let updated = SecretContent(value: newValue, notes: existing.notes, rotatedAt: Self.todayISODate())
        try encryptAndWrite(updated, to: target)
    }

    /// Encrypts and writes a new shared entry.
    ///
    /// Add means create: throws ``VaultError/sharedEntryExists(id:)`` when
    /// `shared/<id>.age` is already present (ho-04.10) — a silent overwrite would
    /// propagate the new value to every scope linked to the entry. Deliberate
    /// replacement is ``rotateShared(_:newValue:)``. Otherwise semantics mirror
    /// ``addSecret(_:value:inScope:notes:)`` but the destination is the vault's
    /// `shared/` directory rather than a scope. Used by the Materializer's ingest
    /// path when the user promotes a scope-local secret to a shared entry.
    ///
    /// - Parameters:
    ///   - id: Shared entry identifier (becomes the filename stem).
    ///   - value: Plaintext value to encrypt.
    ///   - notes: Optional freeform notes stored alongside the value.
    /// - Throws: ``VaultError/sharedEntryExists(id:)`` if the entry already exists;
    ///   ``VaultError/ageInvocationFailed(exitCode:stderr:)`` if `age` exits non-zero;
    ///   ``VaultError/shellNotFound(name:)`` if no age binary is on PATH;
    ///   ``VaultError/yamlEncodeError(path:underlying:)`` if the payload cannot be encoded.
    public func addSharedEntry(
        _ id: String,
        value: String,
        notes: String? = nil
    ) throws {
        let target = try VaultLayout.sharedEntryURL(id, in: vaultURL)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw VaultError.sharedEntryExists(id: id)
        }
        let content = SecretContent(value: value, notes: notes, rotatedAt: Self.todayISODate())
        try encryptAndWrite(content, to: target)
    }

    /// Rotates a shared entry to a new value, preserving notes.
    ///
    /// Every scope that links to this shared entry will resolve the new value on
    /// the next `getValue` call — nothing else needs to be rewritten. No `.link`
    /// files are touched.
    ///
    /// - Throws: `VaultError.sharedEntryNotFound(id:)` if the shared entry is absent.
    public func rotateShared(_ sharedID: String, newValue: String) throws {
        let target = try VaultLayout.sharedEntryURL(sharedID, in: vaultURL)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw VaultError.sharedEntryNotFound(id: sharedID)
        }
        let existing = try decryptSecretContent(at: target)
        let updated = SecretContent(value: newValue, notes: existing.notes, rotatedAt: Self.todayISODate())
        try encryptAndWrite(updated, to: target)
    }

    /// Converts a linked key back into a scope-local direct value.
    ///
    /// Decrypts the shared entry the `<KEY>.link` points at, writes a new
    /// `<KEY>.age` with that value (preserving notes if the shared entry had any),
    /// and deletes the `.link`. After this call, further rotations of the shared
    /// entry no longer propagate to this scope.
    ///
    /// - Throws: `VaultError.secretNotFound(scope:key:)` if no `.link` exists at the key;
    ///   `VaultError.linkTargetMissing(id:)` if the shared entry is absent;
    ///   `VaultError.ageInvocationFailed` for encrypt/decrypt failures.
    public func unlink(_ key: String, inScope scopeID: String) throws {
        let linkURL = try VaultLayout.linkURL(key, inScope: scopeID, in: vaultURL)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: linkURL.path) else {
            throw VaultError.secretNotFound(scope: scopeID, key: key)
        }
        let sharedID = try readLinkTarget(at: linkURL)
        let sharedURL = try VaultLayout.sharedEntryURL(sharedID, in: vaultURL)
        guard fileManager.fileExists(atPath: sharedURL.path) else {
            throw VaultError.linkTargetMissing(id: sharedID)
        }
        let sharedContent = try decryptSecretContent(at: sharedURL)
        let localContent = SecretContent(
            value: sharedContent.value,
            notes: sharedContent.notes,
            rotatedAt: Self.todayISODate()
        )
        let ageURL = try VaultLayout.secretURL(key, inScope: scopeID, in: vaultURL)
        try encryptAndWrite(localContent, to: ageURL)
        do {
            try fileManager.removeItem(at: linkURL)
        } catch {
            throw VaultError.fileSystemError(path: linkURL, underlying: error)
        }
    }

    // MARK: - Encryption helpers

    /// Resolves a scope key to the on-disk file that holds its ciphertext.
    ///
    /// Follows a `<key>.link` to the shared entry when present. Throws if neither
    /// a `.link` nor a `.age` matches, or if a `.link` points to a missing target.
    private func resolveSecretTarget(_ key: String, inScope scopeID: String) throws -> URL {
        let fileManager = FileManager.default
        let linkURL = try VaultLayout.linkURL(key, inScope: scopeID, in: vaultURL)
        if fileManager.fileExists(atPath: linkURL.path) {
            let sharedID = try readLinkTarget(at: linkURL)
            let sharedURL = try VaultLayout.sharedEntryURL(sharedID, in: vaultURL)
            guard fileManager.fileExists(atPath: sharedURL.path) else {
                throw VaultError.linkTargetMissing(id: sharedID)
            }
            return sharedURL
        }
        let ageURL = try VaultLayout.secretURL(key, inScope: scopeID, in: vaultURL)
        guard fileManager.fileExists(atPath: ageURL.path) else {
            throw VaultError.secretNotFound(scope: scopeID, key: key)
        }
        return ageURL
    }

    /// Runs `age --decrypt --identity <keyFile> <cipherURL>` and YAML-decodes stdout.
    private func decryptSecretContent(at cipherURL: URL) throws -> SecretContent {
        guard let ageKeyURL else {
            throw VaultError.ageIdentityNotConfigured
        }
        let ageBinary = try Shell.findExecutable("age")
        let result: ShellResult
        do {
            result = try Shell.run(
                ageBinary,
                ["--decrypt", "--identity", ageKeyURL.path, cipherURL.path]
            )
        } catch {
            throw VaultError.ageInvocationFailed(exitCode: -1, stderr: "\(error)")
        }
        guard result.exitCode == 0 else {
            throw VaultError.ageInvocationFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        do {
            return try YAMLDecoder().decode(SecretContent.self, from: result.stdout)
        } catch {
            // Yams/DecodingError descriptions can embed `result.stdout` — the
            // DECRYPTED payload. Redact before the error can reach a terminal
            // or log; only the error's type name survives.
            throw VaultError.yamlDecodeError(
                path: cipherURL,
                underlying: RedactedDecodeError(originalErrorType: "\(type(of: error))")
            )
        }
    }

    /// YAML-encodes `content`, pipes it to `age --encrypt` via stdin, and
    /// atomically renames the ciphertext into place.
    ///
    /// Two hygiene properties (ho-04.8) this method is responsible for:
    ///
    /// - **The plaintext never touches disk.** It travels only through the
    ///   stdin pipe to `age`. (The previous implementation wrote it to a
    ///   default-permissions temp file with `try?` cleanup.)
    /// - **The destination write is atomic.** `age -o` truncates its output
    ///   target before writing, so pointing it at the real destination would
    ///   let a crash mid-`rotate` destroy the only good ciphertext. Instead
    ///   `age` writes a staging sibling in the destination's directory (same
    ///   volume) which is renamed over the destination on success. A crash
    ///   leftover is ciphertext-only, visible in `git status`, and excluded
    ///   from Conduit's sync commits by ``VaultLayout/stagingPrefix``.
    private func encryptAndWrite(_ content: SecretContent, to destination: URL) throws {
        guard let publicKey else {
            throw VaultError.ageIdentityNotConfigured
        }
        let yaml: String
        do {
            yaml = try YAMLEncoder().encode(content)
        } catch {
            throw VaultError.yamlEncodeError(path: destination, underlying: error)
        }

        // Ensure the destination's parent exists before `age` writes its staging
        // sibling there. `createVaultLayout` runs only from fixtures, so no
        // production path creates `shared/`; a fresh or git-cloned vault (git
        // drops empty directories) arrives without it, and the first shared or
        // scope write would otherwise die with a raw `age` "failed to write
        // header". This is the single write choke point every writer passes
        // through, so ensuring here covers `addSharedEntry`, every scope write,
        // and any future writer (ho-04.12 D8).
        let parent = destination.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw VaultError.fileSystemError(path: parent, underlying: error)
        }

        let staging = VaultLayout.stagingURL(for: destination)
        defer { try? FileManager.default.removeItem(at: staging) }

        let ageBinary = try Shell.findExecutable("age")
        let result: ShellResult
        do {
            result = try Shell.run(
                ageBinary,
                ["--encrypt", "--recipient", publicKey, "-o", staging.path],
                stdin: Data(yaml.utf8)
            )
        } catch {
            throw VaultError.ageInvocationFailed(exitCode: -1, stderr: "\(error)")
        }
        guard result.exitCode == 0 else {
            throw VaultError.ageInvocationFailed(exitCode: result.exitCode, stderr: result.stderr)
        }

        // POSIX rename(2), not FileManager.replaceItemAt: the latter requires
        // an existing destination, but addSecret targets don't exist yet.
        // rename atomically creates-or-replaces on the same volume.
        let fileManager = FileManager.default
        let renameStatus = rename(
            fileManager.fileSystemRepresentation(withPath: staging.path),
            fileManager.fileSystemRepresentation(withPath: destination.path)
        )
        guard renameStatus == 0 else {
            throw VaultError.fileSystemError(
                path: destination,
                underlying: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            )
        }
    }

    /// Today's date in ISO 8601 `YYYY-MM-DD` form (UTC).
    ///
    /// Stored as the `rotated_at` field for new and rotated secrets.
    private static func todayISODate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
