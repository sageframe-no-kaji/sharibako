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
//
// Read-only through ho-06.2: the CLI owned key storage (`sharibako key
// generate`/`import`). ho-06.3's first-run wizard ends that — the wizard is
// now the GUI's own Keychain **write** path (Decision 5), landed below as
// `GUIKeychainAgeKeyProvider.storeIdentity`/`itemExists`, driven by
// `GUIAgeKeyBootstrap` (`GUIAgeKeyBootstrap.swift`).

/// The Keychain service label used for all Sharibako items (same as the CLI's).
///
/// `internal` (not `private`): `GUIAgeKeyBootstrap.swift`'s write path shares
/// this constant rather than redeclaring it, so the service/account/access-group
/// triple stays single-sourced across both the read path here and the write
/// path there (ho-06.3 Decision 5).
let keychainService = "sharibako"

/// The Keychain account label that stores the age private key (same as the CLI's).
///
/// `internal` for the same single-sourcing reason as ``keychainService``.
let keychainAccount = "sharibako.age-key"

/// Keychain access group — must match the app's keychain-access-groups
/// entitlement and the CLI's, so both surfaces unlock the same key.
///
/// `internal` for the same single-sourcing reason as ``keychainService``.
let keychainAccessGroup = "3N8F759K8D.net.sageframe.sharibako"

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
    /// `@MainActor`-isolated: every caller is a `WorkshopModel` intent, which
    /// is itself `@MainActor` (ho-06.1 Decision 1 — key acquisition is user
    /// interaction, not CPU work, so it never hops to ``VaultWorker``). The
    /// Keychain implementation's shared `LAContext` cache (Decision 5) relies
    /// on this confinement to stay `Sendable`-correct without locking.
    ///
    /// - Parameter reason: Human-readable description surfaced as the Touch ID
    ///   prompt string; ignored by `GUIFileAgeKeyProvider`.
    /// - Returns: An `AgeKeyHandle` whose `release()` must be called after use.
    /// - Throws: `AgeKeyAccessError` when the key cannot be produced.
    @MainActor
    func loadIdentity(reason: String) throws -> AgeKeyHandle
}

/// Age-key access failures surfaced by the GUI's providers.
enum AgeKeyAccessError: Error, Equatable {
    /// The age key file at the given path does not exist.
    case keyFileNotFound(path: URL)
    /// The Keychain lookup returned an unexpected OSStatus.
    case keychainLoadFailed(osStatus: Int32)
    /// The Keychain store (`SecItemAdd`) returned an unexpected OSStatus
    /// (ho-06.3 Decision 5 — the wizard's write path).
    case keychainStoreFailed(osStatus: Int32)
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
    /// Holds the one `LAContext` shared across Keychain key loads, so a
    /// successful Touch ID evaluation rides the system's reuse window instead
    /// of re-prompting on every operation (ho-06.1 Decision 5).
    ///
    /// `@MainActor`-isolated rather than `Sendable`-safe by locking: every
    /// call site (`WorkshopModel`'s reveal/add/rotate/materialize intents)
    /// acquires the age key synchronously on the main actor before any
    /// `worker` hop (ho-06.1 Decision 1 — key acquisition is user
    /// interaction, not CPU work), so the cache never needs cross-actor
    /// protection. `LAContext` itself is a mutable Foundation/Obj-C class and
    /// not `Sendable`; confining it to one actor is the correct fix, not a
    /// workaround.
    @MainActor
    private final class GUIKeychainContextCache {
        static let shared = GUIKeychainContextCache()

        private var context: LAContext?

        private init() {}

        /// Returns the shared context, creating one (with the reuse window
        /// configured) if none exists yet or the previous one was
        /// invalidated by a cancelled/failed evaluation.
        ///
        /// `LAContext.touchIDAuthenticationAllowableReuseDuration` set to the
        /// system maximum (`LATouchIDAuthenticationMaximumAllowableReuseDuration`,
        /// 5 minutes) is what lets a second `SecItemCopyMatching` inside the
        /// window skip the biometric prompt — the OS honors the reuse window
        /// per-context, so the context itself must persist across calls
        /// rather than being constructed fresh per operation.
        func currentContext() -> LAContext {
            if let context {
                return context
            }
            let fresh = LAContext()
            fresh.touchIDAuthenticationAllowableReuseDuration =
                LATouchIDAuthenticationMaximumAllowableReuseDuration
            context = fresh
            return fresh
        }

        /// Discards the cached context so the next ``currentContext()`` call
        /// builds a fresh one.
        ///
        /// A cancelled or failed Touch ID evaluation can leave an `LAContext`
        /// unable to evaluate again (invalidated by the system); recreating
        /// on the next load — rather than surfacing a permanent failure —
        /// keeps a single Touch ID cancellation from bricking every
        /// subsequent key load for the rest of the session.
        func invalidate() {
            context = nil
        }
    }

    /// Retrieves the age private key from the macOS Keychain behind Touch ID,
    /// and — since ho-06.3 — stores one there too (the wizard's write path,
    /// Decision 5).
    ///
    /// `loadIdentity` mirrors the CLI's `KeychainAgeKeyProvider.loadIdentity`: a
    /// `SecItemCopyMatching` query against the shared Sharibako item, with an
    /// `LAContext` carrying `reason` so the system prompt names why. The
    /// retrieved key is written to a `0600` temp file; `release()` best-effort
    /// scrubs and deletes it. `storeIdentity`/`itemExists` (below) mirror the
    /// CLI's same-named methods and are driven by `GUIAgeKeyBootstrap`, never
    /// called directly from a view.
    ///
    /// The `LAContext` is shared across every `GUIKeychainAgeKeyProvider`
    /// instance via ``GUIKeychainContextCache`` (ho-06.1 Decision 5): repeated
    /// key loads inside the 5-minute reuse window ride one Touch ID
    /// authentication instead of re-prompting per operation. The Keychain
    /// query itself — service, account, access group, `kSecReturnData` — is
    /// unchanged; only the authentication context is cached. Neither
    /// `storeIdentity` nor `itemExists` touches this cache — writes need no
    /// authentication, and the existence probe is deliberately non-authenticating
    /// (see `itemExists` below).
    struct GUIKeychainAgeKeyProvider: GUIAgeKeyProvider, GUIKeychainStore {
        /// Loads the shared age key item, triggering Touch ID (or password)
        /// unless a prior evaluation is still within the reuse window.
        @MainActor
        func loadIdentity(reason: String) throws -> AgeKeyHandle {
            let context = GUIKeychainContextCache.shared.currentContext()
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
                // A cancelled/failed evaluation can invalidate the context for
                // future use — drop it so the next load builds a fresh one
                // instead of failing permanently for the rest of the session.
                GUIKeychainContextCache.shared.invalidate()
                throw AgeKeyAccessError.keychainLoadFailed(osStatus: status)
            }

            let tempURL = writeTempKeyFile(data)
            let byteCount = data.count
            return AgeKeyHandle(url: tempURL) {
                scrubAndDelete(at: tempURL, byteCount: byteCount)
            }
        }

        /// Writes the age private key to the Keychain, replacing any existing item.
        ///
        /// Mirrors the CLI's `KeychainAgeKeyProvider.storeIdentity`: a
        /// `SecAccessControl` requiring `.userPresence` so every future load
        /// triggers Touch ID, and a delete-then-add so the write always lands
        /// cleanly. Callers gate the overwrite decision themselves —
        /// `GUIAgeKeyBootstrap` never calls this without first checking
        /// ``itemExists()`` (ho-06.3 Decision 1 — never a second key).
        ///
        /// - Parameter contents: Raw bytes of the age private-key file.
        /// - Throws: ``AgeKeyAccessError/keychainStoreFailed(osStatus:)`` when
        ///   `SecAccessControlCreateWithFlags` or `SecItemAdd` returns an error status.
        func storeIdentity(_ contents: Data) throws {
            guard
                let access = SecAccessControlCreateWithFlags(
                    nil,
                    kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                    .userPresence,
                    nil
                )
            else {
                throw AgeKeyAccessError.keychainStoreFailed(osStatus: errSecParam)
            }

            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: keychainAccount,
                kSecAttrAccessGroup as String: keychainAccessGroup,
            ]
            _ = SecItemDelete(deleteQuery as CFDictionary)

            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: keychainAccount,
                kSecAttrAccessGroup as String: keychainAccessGroup,
                kSecValueData as String: contents,
                kSecAttrAccessControl as String: access,
            ]
            let status = SecItemAdd(addQuery as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw AgeKeyAccessError.keychainStoreFailed(osStatus: status)
            }
        }

        /// Returns `true` if a Sharibako age key item already exists in the Keychain.
        ///
        /// Mirrors the CLI's `KeychainAgeKeyProvider.itemExists` +
        /// `KeychainProbe.exists(from:)` combined: an existence-only query (no
        /// `kSecReturnData`, no authentication context) so it never triggers
        /// Touch ID, classifying `errSecSuccess`/`errSecInteractionNotAllowed`
        /// as present, `errSecItemNotFound` as absent, and any other status as
        /// a genuine failure rather than a silent `false` — a false negative
        /// here would let ``GUIAgeKeyBootstrap`` overwrite an existing key.
        ///
        /// - Throws: ``AgeKeyAccessError/keychainLoadFailed(osStatus:)`` for
        ///   any status other than present or absent.
        func itemExists() throws -> Bool {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: keychainAccount,
                kSecAttrAccessGroup as String: keychainAccessGroup,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            let status = SecItemCopyMatching(query as CFDictionary, nil)
            switch status {
            case errSecSuccess, errSecInteractionNotAllowed:
                return true
            case errSecItemNotFound:
                return false
            default:
                throw AgeKeyAccessError.keychainLoadFailed(osStatus: status)
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
