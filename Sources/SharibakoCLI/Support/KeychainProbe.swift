#if os(macOS)
    import Security

    /// Pure classification of a `SecItemCopyMatching` existence-probe status
    /// (ho-04.12 D5).
    ///
    /// Split out of `KeychainAgeKeyProvider` so the branching is testable at the
    /// OSStatus seam without a real Keychain — the provider's actual query stays
    /// coverage-excluded, but this decision does not.
    enum KeychainProbe {
        /// Maps a probe status to present/absent, surfacing anything unexpected.
        ///
        /// `errSecSuccess` means the item is present. `errSecInteractionNotAllowed`
        /// is also treated as present — defensively: it means an item matched but
        /// its access control would need interaction, which still proves
        /// existence, so no caller can ever read it as absent. `errSecItemNotFound`
        /// means absent. Any other status is a genuine Keychain failure and is
        /// thrown rather than collapsed into a silent `false`, which would let a
        /// transient error masquerade as "no key yet" and trigger an unwanted
        /// overwrite.
        static func exists(from status: OSStatus) throws -> Bool {
            switch status {
            case errSecSuccess, errSecInteractionNotAllowed:
                return true
            case errSecItemNotFound:
                return false
            default:
                throw CLIError.keychainLoadFailed(osStatus: status)
            }
        }
    }
#endif
