#if os(macOS)
    import Foundation
    import LocalAuthentication
    import Security

    /// The Keychain service label used for all Sharibako items.
    private let keychainService = "sharibako"

    /// The Keychain account label that stores the age private key.
    private let keychainAccount = "sharibako.age-key"

    // Keychain access group — must match the keychain-access-groups entitlement.
    // CLI tools have no implicit bundle ID, so the group is declared explicitly.
    private let keychainAccessGroup = "3N8F759K8D.net.sageframe.sharibako"

    /// Retrieves and stores the age private key in the macOS Keychain.
    ///
    /// Access is gated by a `SecAccessControl` configured with `.userPresence`,
    /// which triggers Touch ID (or password) on every retrieval. A `LAContext`
    /// carrying the `reason` string is attached to the query so the system prompt
    /// displays a meaningful description.
    ///
    /// The retrieved key is written to a `0600` temp file and returned as an
    /// `AgeKeyHandle`. The handle's `release()` closure best-effort scrubs and
    /// deletes the temp file.
    struct KeychainAgeKeyProvider: AgeKeyProvider {
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
                throw CLIError.keychainLoadFailed(osStatus: status)
            }

            let tempURL = writeTempKeyFile(data)
            let byteCount = data.count

            // Trap fatal signals for the temp key's whole lifetime: an interrupt
            // in this window (Ctrl-C during Touch ID, a kill from another
            // terminal) would otherwise leave the plaintext key on disk (D1).
            let signalGuard = TempKeySignalGuard {
                scrubAndDelete(at: tempURL, byteCount: byteCount)
            }
            signalGuard.install()

            return AgeKeyHandle(url: tempURL) {
                signalGuard.teardown()
                scrubAndDelete(at: tempURL, byteCount: byteCount)
            }
        }

        /// Writes the age private key to the Keychain, replacing any existing item.
        ///
        /// Creates a `SecAccessControl` requiring `.userPresence` so subsequent
        /// retrievals trigger Touch ID.
        ///
        /// - Parameter contents: Raw bytes of the age private-key file.
        /// - Throws: `CLIError.keychainStoreFailed` when `SecAccessControlCreateWithFlags`
        ///   or `SecItemAdd` returns an error status.
        func storeIdentity(_ contents: Data) throws {
            // Build access control requiring biometry or device passcode.
            guard
                let access = SecAccessControlCreateWithFlags(
                    nil,
                    kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                    .userPresence,
                    nil
                )
            else {
                throw CLIError.keychainStoreFailed(osStatus: errSecParam)
            }

            // Delete any pre-existing item first; ignore "item not found".
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
                throw CLIError.keychainStoreFailed(osStatus: status)
            }
        }

        /// Retrieves the raw age private-key bytes from the Keychain.
        ///
        /// Triggers Touch ID or password prompt.
        func exportIdentity(reason: String) throws -> Data {
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
                throw CLIError.keychainLoadFailed(osStatus: status)
            }
            return data
        }

        /// Returns `true` if a Sharibako age key item already exists in the Keychain.
        ///
        /// Existence-only probe: it requests neither the secret data nor an
        /// authentication context, so it never triggers Touch ID. The item's
        /// `.userPresence` access control guards the secret *value*, not the
        /// item's presence — a match by service/account/group returns
        /// `errSecSuccess` without evaluating the ACL.
        ///
        /// It deliberately does NOT attach `LAContext.interactionNotAllowed` (nor
        /// the deprecated `kSecUseAuthenticationUIFail`): that flag tells the
        /// Keychain to treat any item that *would* require interaction as
        /// non-matching, so a Touch-ID-protected key reports `errSecItemNotFound`
        /// — a false negative that let `key generate` overwrite an existing key
        /// (ho-04.12 dogfood). The status is classified by
        /// ``KeychainProbe/exists(from:)``, which throws on an unexpected status
        /// rather than reporting a silent `false`.
        ///
        /// - Throws: `CLIError.keychainLoadFailed` for any status other than
        ///   present (`errSecSuccess`/`errSecInteractionNotAllowed`) or absent
        ///   (`errSecItemNotFound`).
        func itemExists() throws -> Bool {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: keychainAccount,
                kSecAttrAccessGroup as String: keychainAccessGroup,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            let status = SecItemCopyMatching(query as CFDictionary, nil)
            return try KeychainProbe.exists(from: status)
        }
    }

    // MARK: - Private helpers

    /// Writes `data` to a new `0600` temp file and returns its URL.
    private func writeTempKeyFile(_ data: Data) -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharibako-key-\(UUID().uuidString)")
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
