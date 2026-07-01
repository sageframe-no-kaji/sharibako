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
        let scopeDir = VaultLayout.scopeDirectoryURL(scopeID, in: vaultURL)
        guard FileManager.default.fileExists(atPath: scopeDir.path) else {
            throw VaultError.scopeNotFound(id: scopeID)
        }
        let target = VaultLayout.secretURL(key, inScope: scopeID, in: vaultURL)
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
        let target = try resolveSecretTarget(key, inScope: scopeID)
        let content = try decryptSecretContent(at: target)
        return content.value
    }

    /// Rotates a scope-local secret to a new value, preserving notes.
    ///
    /// Reads the existing `<KEY>.age`, updates `value` and `rotated_at`, and
    /// re-encrypts to the same path.
    ///
    /// - Throws: `VaultError.secretNotFound(scope:key:)` if the `.age` is absent;
    ///   `VaultError.ageInvocationFailed` for encrypt/decrypt failures.
    public func rotate(_ key: String, inScope scopeID: String, newValue: String) throws {
        let target = VaultLayout.secretURL(key, inScope: scopeID, in: vaultURL)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw VaultError.secretNotFound(scope: scopeID, key: key)
        }
        let existing = try decryptSecretContent(at: target)
        let updated = SecretContent(value: newValue, notes: existing.notes, rotatedAt: Self.todayISODate())
        try encryptAndWrite(updated, to: target)
    }

    /// Encrypts and writes a new shared entry.
    ///
    /// Overwrites any existing `shared/<id>.age` at the same path. Semantics mirror
    /// ``addSecret(_:value:inScope:notes:)`` but the destination is the vault's
    /// `shared/` directory rather than a scope. Used by the Materializer's ingest
    /// path when the user promotes a scope-local secret to a shared entry.
    ///
    /// - Parameters:
    ///   - id: Shared entry identifier (becomes the filename stem).
    ///   - value: Plaintext value to encrypt.
    ///   - notes: Optional freeform notes stored alongside the value.
    /// - Throws: ``VaultError/ageInvocationFailed(exitCode:stderr:)`` if `age` exits non-zero;
    ///   ``VaultError/shellNotFound(name:)`` if no age binary is on PATH;
    ///   ``VaultError/yamlEncodeError(path:underlying:)`` if the payload cannot be encoded.
    public func addSharedEntry(
        _ id: String,
        value: String,
        notes: String? = nil
    ) throws {
        let target = VaultLayout.sharedEntryURL(id, in: vaultURL)
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
        let target = VaultLayout.sharedEntryURL(sharedID, in: vaultURL)
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
        let linkURL = VaultLayout.linkURL(key, inScope: scopeID, in: vaultURL)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: linkURL.path) else {
            throw VaultError.secretNotFound(scope: scopeID, key: key)
        }
        let sharedID = try readLinkTarget(at: linkURL)
        let sharedURL = VaultLayout.sharedEntryURL(sharedID, in: vaultURL)
        guard fileManager.fileExists(atPath: sharedURL.path) else {
            throw VaultError.linkTargetMissing(id: sharedID)
        }
        let sharedContent = try decryptSecretContent(at: sharedURL)
        let localContent = SecretContent(
            value: sharedContent.value,
            notes: sharedContent.notes,
            rotatedAt: Self.todayISODate()
        )
        let ageURL = VaultLayout.secretURL(key, inScope: scopeID, in: vaultURL)
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
        let linkURL = VaultLayout.linkURL(key, inScope: scopeID, in: vaultURL)
        if fileManager.fileExists(atPath: linkURL.path) {
            let sharedID = try readLinkTarget(at: linkURL)
            let sharedURL = VaultLayout.sharedEntryURL(sharedID, in: vaultURL)
            guard fileManager.fileExists(atPath: sharedURL.path) else {
                throw VaultError.linkTargetMissing(id: sharedID)
            }
            return sharedURL
        }
        let ageURL = VaultLayout.secretURL(key, inScope: scopeID, in: vaultURL)
        guard fileManager.fileExists(atPath: ageURL.path) else {
            throw VaultError.secretNotFound(scope: scopeID, key: key)
        }
        return ageURL
    }

    /// Runs `age --decrypt --identity <keyFile> <cipherURL>` and YAML-decodes stdout.
    private func decryptSecretContent(at cipherURL: URL) throws -> SecretContent {
        guard let ageKeyURL else {
            throw VaultError.shellNotFound(name: "age")
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
            throw VaultError.yamlDecodeError(path: cipherURL, underlying: error)
        }
    }

    /// YAML-encodes `content`, writes it to a temp file, and runs
    /// `age --encrypt --recipient <pub> -o <dest> <tempFile>`.
    private func encryptAndWrite(_ content: SecretContent, to destination: URL) throws {
        guard let publicKey else {
            throw VaultError.shellNotFound(name: "age")
        }
        let yaml: String
        do {
            yaml = try YAMLEncoder().encode(content)
        } catch {
            throw VaultError.yamlEncodeError(path: destination, underlying: error)
        }

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharibako-\(UUID().uuidString).yaml")
        do {
            try yaml.write(to: tempFile, atomically: true, encoding: .utf8)
        } catch {
            throw VaultError.fileSystemError(path: tempFile, underlying: error)
        }
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let ageBinary = try Shell.findExecutable("age")
        let result: ShellResult
        do {
            result = try Shell.run(
                ageBinary,
                ["--encrypt", "--recipient", publicKey, "-o", destination.path, tempFile.path]
            )
        } catch {
            throw VaultError.ageInvocationFailed(exitCode: -1, stderr: "\(error)")
        }
        guard result.exitCode == 0 else {
            throw VaultError.ageInvocationFailed(exitCode: result.exitCode, stderr: result.stderr)
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
