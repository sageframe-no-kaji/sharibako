import Foundation
import Testing

@testable import SharibakoCore

/// Tests for `Conduit.removeRemote` (ho-06.10 AT-04: the Workshop's Remote…
/// sheet can unset the vault's remote).
@Suite("Conduit Remove Remote")
struct ConduitRemoveRemoteTests {
    @Test("removeRemote unsets a configured origin")
    func removeRemoteUnsetsOrigin() throws {
        try VaultTestSupport.withEphemeralGitVault { vault in
            let conduit = try Conduit(vaultURL: vault)
            try conduit.setRemote("https://example.invalid/repo.git")
            try conduit.removeRemote()
            #expect(try conduit.remoteURL() == nil)
        }
    }

    @Test("removeRemote is a quiet no-op when no origin is configured")
    func removeRemoteWithoutOrigin() throws {
        try VaultTestSupport.withEphemeralGitVault { vault in
            let conduit = try Conduit(vaultURL: vault)
            try conduit.removeRemote()
            #expect(try conduit.remoteURL() == nil)
        }
    }

    @Test("a removed remote can be set again")
    func removeThenSetAgain() throws {
        try VaultTestSupport.withEphemeralGitVault { vault in
            let conduit = try Conduit(vaultURL: vault)
            try conduit.setRemote("https://example.invalid/first.git")
            try conduit.removeRemote()
            try conduit.setRemote("https://example.invalid/second.git")
            #expect(try conduit.remoteURL() == "https://example.invalid/second.git")
        }
    }
}
