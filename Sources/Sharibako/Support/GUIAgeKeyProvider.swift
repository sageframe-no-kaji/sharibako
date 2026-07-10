import Foundation

#if os(macOS)
    import LocalAuthentication
    import Security
#endif

// The GUI's own age-key access adapter (ho-05 Decision 1). This deliberately
// MIRRORS the CLI's AgeKeyProvider/KeychainAgeKeyProvider pattern rather than
// importing it: SharibakoCLI is a closed executable target the GUI cannot
// depend on, and SharibakoCore stays portable (no Security/LocalAuthentication).
// Both surfaces read the same Keychain item, so a vault set up via the CLI
// opens in the Workshop with no re-keying. The CLI's TempKeySignalGuard is NOT
// ported — the GUI is not a signal-driven CLI; `release()` is the whole cleanup.

/// The Keychain service label used for all Sharibako items (same as the CLI's).
private let keychainService = "sharibako"

/// The Keychain account label that stores the age private key (same as the CLI's).
private let keychainAccount = "sharibako.age-key"

// Keychain access group — must match the app's keychain-access-groups
// entitlement and the CLI's, so both surfaces unlock the same key.
private let keychainAccessGroup = "3N8F759K8D.net.sageframe.sharibako"

/// A handle wrapping the URL of an age identity file for the duration of one operation.
///
/// Call `release()` when the operation completes. `GUIKeychainAgeKeyProvider`
/// uses the cleanup closure to scrub and delete its temp file;
/// `GUIFileAgeKeyProvider`'s cleanup is a no-op.
struct AgeKeyHandle: Sendable {
    /// Absolute URL of the age private-key file the caller passes to `age --identity`.
    let url: URL

    private let cleanup: @Sendable () -> Void

    /// Creates a handle with the given URL and cleanup action.
    init(url: URL, cleanup: @escaping @Sendable () -> Void) {
        self.url = url
        self.cleanup = cleanup
    }

    /// Runs the cleanup closure.
    func release() { cleanup() }
}

/// Provides an age identity file for the duration of one vault operation.
///
/// Two concrete implementations exist:
/// - `GUIFileAgeKeyProvider` — hands back a caller-supplied key file; the dev/test bypass.
/// - `GUIKeychainAgeKeyProvider` — retrieves from the macOS Keychain with Touch ID.
protocol GUIAgeKeyProvider: Sendable {
    /// Returns a handle whose `url` points at an age identity file.
    ///
    /// - Parameter reason: Human-readable description surfaced as the Touch ID
    ///   prompt string; ignored by `GUIFileAgeKeyProvider`.
    /// - Returns: An `AgeKeyHandle` whose `release()` must be called after use.
    /// - Throws: `AgeKeyAccessError` when the key cannot be produced.
    func loadIdentity(reason: String) throws -> AgeKeyHandle
}

/// Age-key access failures surfaced by the GUI's providers.
enum AgeKeyAccessError: Error, Equatable {
    /// The age key file at the given path does not exist.
    case keyFileNotFound(path: URL)
    /// The Keychain lookup returned an unexpected OSStatus.
    case keychainLoadFailed(osStatus: Int32)
}

/// Hands the caller a pre-existing age key file directly.
///
/// The file is never copied or deleted — `release()` is a no-op. Selected by
/// `WorkshopModel` when `SHARIBAKO_AGE_KEY` is set: the dev/test bypass for
/// unsigned builds that cannot reach the Keychain entitlement (Decision 7).
struct GUIFileAgeKeyProvider: GUIAgeKeyProvider {
    /// Absolute URL of the age private-key file.
    let path: URL

    /// Returns the configured key file, verifying it exists.
    func loadIdentity(reason: String) throws -> AgeKeyHandle {
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw AgeKeyAccessError.keyFileNotFound(path: path)
        }
        return AgeKeyHandle(url: path) {}
    }
}

#if os(macOS)
    /// Retrieves the age private key from the macOS Keychain behind Touch ID.
    ///
    /// Mirrors the CLI's `KeychainAgeKeyProvider.loadIdentity`: a
    /// `SecItemCopyMatching` query against the shared Sharibako item, with an
    /// `LAContext` carrying `reason` so the system prompt names why. The
    /// retrieved key is written to a `0600` temp file; `release()` best-effort
    /// scrubs and deletes it. Read-only — the CLI owns key storage
    /// (`sharibako key generate`/`import`).
    struct GUIKeychainAgeKeyProvider: GUIAgeKeyProvider {
        /// Loads the shared age key item, triggering Touch ID (or password).
        func loadIdentity(reason: String) throws -> AgeKeyHandle {
            let context = LAContext()
            context.localizedReason = reason

            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: keychainAccount,
                kSecAttrAccessGroup as String: keychainAccessGroup,
                kSecReturnData as String: true,
                kSecUseAuthenticationContext as String: context,
            ]
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess, let data = result as? Data else {
                throw AgeKeyAccessError.keychainLoadFailed(osStatus: status)
            }

            let tempURL = writeTempKeyFile(data)
            let byteCount = data.count
            return AgeKeyHandle(url: tempURL) {
                scrubAndDelete(at: tempURL, byteCount: byteCount)
            }
        }
    }

    /// Writes `data` to a new `0600` temp file and returns its URL.
    private func writeTempKeyFile(_ data: Data) -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharibako-workshop-key-\(UUID().uuidString)")
        FileManager.default.createFile(
            atPath: tempURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        )
        return tempURL
    }

    /// Best-effort in-memory scrub followed by file removal.
    private func scrubAndDelete(at url: URL, byteCount: Int) {
        // Overwrite with zeros before deletion — reduces window for key recovery.
        if let handle = try? FileHandle(forWritingTo: url) {
            let zeros = Data(repeating: 0, count: byteCount)
            try? handle.write(contentsOf: zeros)
            try? handle.close()
        }
        try? FileManager.default.removeItem(at: url)
    }
#endif
