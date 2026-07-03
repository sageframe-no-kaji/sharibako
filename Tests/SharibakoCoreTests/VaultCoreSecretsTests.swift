import Foundation
import Testing

@testable import SharibakoCore

/// Tests for `VaultCore.secrets(inScope:)` — the bulk-decrypt helper `sharibako run` uses.
@Suite("VaultCore.secrets(inScope:)")
struct VaultCoreSecretsTests {
    @Test("Returns every owned key's decrypted value")
    func returnsAllOwnedValues() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("demo", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("FOO", value: "bar-123", inScope: "demo")
            try core.addSecret("BAZ", value: "qux-456", inScope: "demo")

            let secrets = try core.secrets(inScope: "demo")
            #expect(secrets == ["FOO": "bar-123", "BAZ": "qux-456"])
        }
    }

    @Test("Resolves a linked key to its shared entry's value")
    func resolvesLink() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("demo", type: .projectDev, in: vault)
            try VaultTestSupport.writeSharedEntry(
                "openai-personal", value: "sk-shared-xyz", vault: vault, fixture: fixture
            )
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("LOCAL", value: "local-val", inScope: "demo")
            try core.link("OPENAI_API_KEY", inScope: "demo", toShared: "openai-personal")

            let secrets = try core.secrets(inScope: "demo")
            #expect(secrets == ["LOCAL": "local-val", "OPENAI_API_KEY": "sk-shared-xyz"])
        }
    }

    @Test("Returns an empty dictionary for a scope with no owned keys")
    func emptyScope() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("empty", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            #expect(try core.secrets(inScope: "empty").isEmpty)
        }
    }

    @Test("Throws scopeNotFound for an absent scope")
    func absentScope() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            let error = #expect(throws: VaultError.self) {
                _ = try core.secrets(inScope: "ghost")
            }
            guard case .scopeNotFound(let id) = error else {
                Issue.record("expected scopeNotFound, got \(String(describing: error))")
                return
            }
            #expect(id == "ghost")
        }
    }

    @Test("Throws linkTargetMissing when a link points at a missing shared entry")
    func danglingLink() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("demo", type: .projectDev, in: vault)
            try VaultTestSupport.writeLink("KEY", inScope: "demo", sharedID: "nonexistent", in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            let error = #expect(throws: VaultError.self) {
                _ = try core.secrets(inScope: "demo")
            }
            guard case .linkTargetMissing(let id) = error else {
                Issue.record("expected linkTargetMissing, got \(String(describing: error))")
                return
            }
            #expect(id == "nonexistent")
        }
    }
}
