import Foundation
import SharibakoCore

/// The Keychain write/probe seam `GUIAgeKeyBootstrap` writes through.
///
/// `GUIKeychainAgeKeyProvider` (`GUIAgeKeyProvider.swift`) is the real,
/// signed-app-only implementation — reaching the Keychain access group
/// needs the entitlement a bare CI test binary cannot have (the same
/// constraint that keeps `KeychainAgeKeyProvider` and `GUIAgeKeyProvider.swift`
/// itself CI-excluded). Tests inject a fake conforming type instead, so
/// `GUIAgeKeyBootstrap`'s own branching — validation, extraction, the
/// never-overwrite guard — carries real coverage without ever touching the
/// real Keychain (ho-06.3 Decision 5, Do Not §4).
protocol GUIKeychainStore {
    /// Stores `contents` under `.userPresence`, replacing any existing item.
    func storeIdentity(_ contents: Data) throws

    /// `true` when a Sharibako age key item already exists.
    func itemExists() throws -> Bool
}

/// Bootstrap-specific validation failures for `GUIAgeKeyBootstrap`.
///
/// Distinct from `AgeKeyAccessError` (`GUIAgeKeyProvider.swift`), which
/// covers Keychain OSStatus failures — these two cases are about the
/// *content* of an age key file, independent of where it ends up stored.
enum GUIAgeKeyBootstrapError: Error, Equatable {
    /// A key file has no `# public key:` header line. Unreachable for a
    /// freshly generated key (real `age-keygen` always writes one); reachable
    /// for `importToKeychain` when the file also has no derivable recipient.
    case publicKeyHeaderMissing
    /// The file at `path` does not contain an `AGE-SECRET-KEY-1` line — not a
    /// usable age identity.
    case invalidIdentityFile(path: URL)
}

/// Generates, imports, and probes for the Workshop's age key — the wizard's
/// Keychain **write** path (ho-06.3 Decision 5), mirroring the CLI's
/// `AgeKeyBootstrap` the way `GUIAgeKeyProvider` already mirrors
/// `KeychainAgeKeyProvider` for reads: the same service/account/access-group
/// constants (hoisted `internal` in `GUIAgeKeyProvider.swift`), the same
/// `.userPresence` access control, the same delete-then-add store.
/// `SharibakoCLI` is a closed executable target the GUI cannot depend on, so
/// the shell-out and validation logic below is re-authored, not imported.
enum GUIAgeKeyBootstrap {
    /// `true` when both `age` and `age-keygen` resolve through the PATH-plus-
    /// fallback lookup in `GUIShell` (Decision 1's page-1 prereq gate).
    ///
    /// Even key *import* needs `age` for every later encrypt, so both
    /// binaries gate together.
    static func prerequisitesPresent() -> Bool {
        (try? GUIShell.findExecutable("age")) != nil
            && (try? GUIShell.findExecutable("age-keygen")) != nil
    }

    /// `true` when a Sharibako age key already exists in the Keychain —
    /// mirrors the CLI's non-authenticating existence probe (Decision 1:
    /// this page never generates a second key when one is already there).
    static func keychainKeyExists(store: GUIKeychainStore) throws -> Bool {
        try store.itemExists()
    }

    /// Generates a fresh age key, stores it in the Keychain under
    /// `.userPresence`, and returns the identity text (for the backup save
    /// panel) and recipient (for display) — held only long enough for the
    /// backup page (Decision 1 step 2, Decision 2).
    ///
    /// Mirrors the CLI's `AgeKeyBootstrap.generateToKeychain`: `age-keygen`
    /// to a `0600` temp file, store the raw bytes, scrub and delete the temp
    /// file on every exit path (success or failure).
    ///
    /// - Parameter store: The Keychain write seam; production callers pass
    ///   `GUIKeychainAgeKeyProvider()`, tests pass a fake.
    /// - Returns: The generated identity's full text and its `age1…` recipient.
    /// - Throws: `VaultError.shellNotFound`/`.ageInvocationFailed` if
    ///   `age-keygen` cannot run; the store's own error type if the Keychain
    ///   write fails.
    static func generateToKeychain(
        store: GUIKeychainStore
    ) throws -> (identity: String, recipient: String) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharibako-wizard-keygen-\(UUID().uuidString)")
        defer { scrubAndDelete(at: tempURL) }
        let ageKeygen = try GUIShell.findExecutable("age-keygen")
        let result = try GUIShell.run(ageKeygen, ["-o", tempURL.path])
        guard result.exitCode == 0 else {
            throw VaultError.ageInvocationFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        let data = try Data(contentsOf: tempURL)
        // The failable initializer, not the lossy `String(decoding:as:)` —
        // corrupted `age-keygen` output should surface as a missing header
        // below, never get silently mangled into replacement characters.
        let identity = String(bytes: data, encoding: .utf8) ?? ""
        // Extract before store: a `age-keygen` output that somehow lacks its
        // header must never land in the Keychain — the recipient has to be
        // known before the write, not discovered after (the same ordering
        // `importToKeychain` below follows for the same reason).
        let recipient = try extractPublicKey(from: identity)
        try store.storeIdentity(data)
        return (identity, recipient)
    }

    /// Validates and stores an existing identity file (Decision 1 step 2's
    /// import path; Decision 2 — import skips the backup nudge, the file
    /// already lives outside the Keychain).
    ///
    /// Recipient derivation prefers the file's own `# public key:` header
    /// (real `age-keygen` output always carries one); a hand-made identity
    /// file without the header falls back to `age-keygen -y <file>`, which
    /// prints an identity's recipient without altering the file. That
    /// fallback has no CLI precedent — the CLI's own `key import` relies
    /// solely on the header — but the wizard cannot ask a non-expert to
    /// regenerate a header-less key by hand.
    ///
    /// - Parameters:
    ///   - url: The identity file the user picked via the file importer.
    ///   - store: The Keychain write seam; production callers pass
    ///     `GUIKeychainAgeKeyProvider()`, tests pass a fake.
    /// - Returns: The file's full contents and its derived recipient.
    /// - Throws: `GUIAgeKeyBootstrapError.invalidIdentityFile` when the file
    ///   has no `AGE-SECRET-KEY-1` line; the store's own error type if the
    ///   Keychain write fails.
    static func importToKeychain(
        from url: URL,
        store: GUIKeychainStore
    ) throws -> (identity: String, recipient: String) {
        let data = try Data(contentsOf: url)
        // The failable initializer: a non-UTF8 file is not a usable identity
        // file, and decoding it losslessly-but-mangled would only produce a
        // confusing downstream failure instead of the direct one here.
        let contents = String(bytes: data, encoding: .utf8) ?? ""
        guard containsIdentityLine(contents) else {
            throw GUIAgeKeyBootstrapError.invalidIdentityFile(path: url)
        }
        // Derive before store: a file that passes the loose prefix check but
        // fails `age-keygen -y` validation (garbage after the marker) must
        // never overwrite the Keychain's existing item with an unconfirmed
        // key — derivation failure has to surface before the write, not after.
        let recipient = try (try? extractPublicKey(from: contents)) ?? deriveRecipient(from: url)
        try store.storeIdentity(data)
        return (contents, recipient)
    }

    // MARK: - Private helpers

    /// `true` when `contents` has a non-comment line beginning
    /// `AGE-SECRET-KEY-1` — the identity marker `age-keygen` writes.
    private static func containsIdentityLine(_ contents: String) -> Bool {
        contents.split(whereSeparator: \.isNewline)
            .contains { $0.hasPrefix("AGE-SECRET-KEY-1") }
    }

    /// Extracts the `age1…` recipient from an identity file's `# public key:`
    /// header (mirrors the CLI's `extractPublicKey`, `KeyCommand.swift`).
    private static func extractPublicKey(from contents: String) throws -> String {
        let prefix = "# public key: "
        for line in contents.split(whereSeparator: \.isNewline) where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        throw GUIAgeKeyBootstrapError.publicKeyHeaderMissing
    }

    /// Derives the recipient for a hand-made identity file with no
    /// `# public key:` header, via `age-keygen -y <file>`.
    private static func deriveRecipient(from url: URL) throws -> String {
        let ageKeygen = try GUIShell.findExecutable("age-keygen")
        let result = try GUIShell.run(ageKeygen, ["-y", url.path])
        guard result.exitCode == 0 else {
            throw VaultError.ageInvocationFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        let recipient = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recipient.isEmpty else {
            throw GUIAgeKeyBootstrapError.publicKeyHeaderMissing
        }
        return recipient
    }

    /// Best-effort scrub-then-delete of a temp key file — mirrors the CLI's
    /// `scrubAndDelete` (private to `KeychainAgeKeyProvider.swift`).
    private static func scrubAndDelete(at url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            let zeros = Data(repeating: 0, count: data.count)
            try? handle.write(contentsOf: zeros)
            try? handle.close()
        }
        try? FileManager.default.removeItem(at: url)
    }
}
