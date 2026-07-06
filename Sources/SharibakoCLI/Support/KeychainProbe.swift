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
        /// `errSecSuccess` means the item is present and readable; the
        /// non-interactive probe (`LAContext.interactionNotAllowed`) also reports
        /// `errSecInteractionNotAllowed` when the item is present but its access
        /// control would require user interaction we deliberately forbade — that
        /// still proves existence. `errSecItemNotFound` means absent. Any other
        /// status is a genuine Keychain failure and is thrown rather than
        /// collapsed into a silent `false`, which would let a transient error
        /// masquerade as "no key yet" and trigger an unwanted overwrite.
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
