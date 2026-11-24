import Foundation
import Testing

@testable import SharibakoCore

/// Tests for `VaultCore.getSharedValue` (ho-06.10 Decision 9) — reading one
/// shared entry by its ID, for the Workshop's value match during Check all.
@Suite("VaultCore Shared Value")
struct VaultCoreSharedValueTests {
    @Test("getSharedValue decrypts a shared entry's value")
    func getSharedValueRoundTrip() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSharedEntry("openai-personal", value: "sk-live-abc", notes: "primary")
            #expect(try core.getSharedValue("openai-personal") == "sk-live-abc")
        }
    }

    @Test("getSharedValue throws sharedEntryNotFound for an absent entry")
    func getSharedValueMissing() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            do {
                _ = try core.getSharedValue("nope")
                Issue.record("Expected sharedEntryNotFound")
            } catch VaultError.sharedEntryNotFound(let id) {
                #expect(id == "nope")
            }
        }
    }

    @Test("getSharedValue rejects an ID outside the identifier grammar")
    func getSharedValueInvalidID() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            #expect(throws: VaultError.self) {
                try core.getSharedValue("../escape")
            }
        }
    }
}
