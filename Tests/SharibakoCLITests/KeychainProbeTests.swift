#if os(macOS)
    import Security
    import Testing

    @testable import SharibakoCLI

    /// OSStatus-seam tests for the Keychain existence probe (ho-04.12 D5).
    ///
    /// The real `SecItemCopyMatching` call needs the signed Keychain entitlement
    /// and is dogfood-verified; the branching that turns its status into
    /// present/absent/error is pure and tested here across the enumerated cases.
    @Suite("KeychainProbe")
    struct KeychainProbeTests {
        @Test("errSecSuccess means the item is present")
        func successIsPresent() throws {
            #expect(try KeychainProbe.exists(from: errSecSuccess))
        }

        @Test("errSecInteractionNotAllowed means present-but-guarded")
        func interactionNotAllowedIsPresent() throws {
            // The item exists; its access control would prompt, which the
            // non-interactive probe forbade. Existence is still proven.
            #expect(try KeychainProbe.exists(from: errSecInteractionNotAllowed))
        }

        @Test("errSecItemNotFound means absent")
        func itemNotFoundIsAbsent() throws {
            #expect(try KeychainProbe.exists(from: errSecItemNotFound) == false)
        }

        @Test("An unexpected status is surfaced as an error, not a silent false")
        func unexpectedStatusThrows() {
            // Old behavior collapsed everything non-present to false; a transient
            // failure would then read as "no key" and could trigger an overwrite.
            let error = #expect(throws: CLIError.self) {
                _ = try KeychainProbe.exists(from: errSecAuthFailed)
            }
            guard case .keychainLoadFailed(let osStatus) = error else {
                Issue.record("expected keychainLoadFailed, got \(String(describing: error))")
                return
            }
            #expect(osStatus == errSecAuthFailed)
        }
    }
#endif
