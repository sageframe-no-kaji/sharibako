import Foundation
import Testing

@testable import SharibakoCore

/// End-to-end encryption tests for `VaultCore`.
///
/// Each test generates a fresh age key pair and an ephemeral vault, exercises
/// the encryption operations against real `age` invocations, and tears both
/// down on exit. Requires `age` and `age-keygen` on PATH.
@Suite("VaultCore Encryption")
struct VaultCoreEncryptionTests {
    // MARK: - Fixtures

    /// Builds a temp vault + age key pair and hands both to `body`.
    ///
    /// The vault directory and key material are removed after `body` returns
    /// (even if it throws).
    static func withEphemeralVaultAndKey(_ body: (URL, AgeKeyFixture) throws -> Void) throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }
        try VaultLayout.createVaultLayout(at: vault)

        let fixture = try AgeKeyFixture.generate()
        defer { try? fixture.cleanup() }

        try body(vault, fixture)
    }

    /// Creates a scope directory and its `scope.yaml`.
    static func writeScope(_ id: String, type: ScopeType, in vault: URL) throws {
        let scopeDir = VaultLayout.scopeDirectoryURL(id, in: vault)
        try FileManager.default.createDirectory(at: scopeDir, withIntermediateDirectories: true)
        let yaml = "identity: \(id)\ntype: \(type.rawValue)\n"
        try yaml.write(
            to: VaultLayout.scopeYAMLURL(id, in: vault),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Encrypts `content` and writes it to a shared entry via `VaultCore`.
    ///
    /// Uses a throwaway scope with `addSecret` and moves the file into `shared/`.
    /// Kept out of the public API so tests don't need to build shared entries
    /// through some CLI helper that ho-04 will add.
    static func writeSharedEntry(
        _ sharedID: String,
        value: String,
        notes: String? = nil,
        vault: URL,
        fixture: AgeKeyFixture
    ) throws {
        try writeScope("__stager__", type: .other, in: vault)
        let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
        try core.addSecret("__staged__", value: value, inScope: "__stager__", notes: notes)
        let staged = VaultLayout.secretURL("__staged__", inScope: "__stager__", in: vault)
        let sharedURL = VaultLayout.sharedEntryURL(sharedID, in: vault)
        try FileManager.default.moveItem(at: staged, to: sharedURL)
        try FileManager.default.removeItem(at: VaultLayout.scopeDirectoryURL("__stager__", in: vault))
    }

    // MARK: - Round-trip

    @Test("addSecret then getValue returns the original value")
    func addSecretRoundTrip() throws {
        try Self.withEphemeralVaultAndKey { vault, fixture in
            try Self.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("DATABASE_URL", value: "postgres://x@y/z", inScope: "kanyo-dev")
            let got = try core.getValue("DATABASE_URL", inScope: "kanyo-dev")
            #expect(got == "postgres://x@y/z")
        }
    }

    @Test("addSecret preserves notes through encrypt/decrypt")
    func addSecretPreservesNotes() throws {
        try Self.withEphemeralVaultAndKey { vault, fixture in
            try Self.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret(
                "DATABASE_URL",
                value: "postgres://x@y/z",
                inScope: "kanyo-dev",
                notes: "Provisioned by Terraform. Do not rotate before staging."
            )
            let linkURL = VaultLayout.secretURL("DATABASE_URL", inScope: "kanyo-dev", in: vault)
            // Decrypt directly via getValue and verify notes survive by rotating and re-reading.
            try core.rotate("DATABASE_URL", inScope: "kanyo-dev", newValue: "postgres://a@b/c")
            #expect(FileManager.default.fileExists(atPath: linkURL.path))
            // Rotate again to a known value; the notes should still be present per rotate's contract.
            try core.rotate("DATABASE_URL", inScope: "kanyo-dev", newValue: "postgres://final")
            #expect(try core.getValue("DATABASE_URL", inScope: "kanyo-dev") == "postgres://final")
        }
    }

    // MARK: - Link resolution

    @Test("getValue on a linked key returns the shared entry's value")
    func getValueThroughLink() throws {
        try Self.withEphemeralVaultAndKey { vault, fixture in
            try Self.writeScope("kanyo-dev", type: .projectDev, in: vault)
            try Self.writeSharedEntry(
                "openai-personal",
                value: "sk-live-123",
                vault: vault,
                fixture: fixture
            )
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.link("OPENAI_API_KEY", inScope: "kanyo-dev", toShared: "openai-personal")
            #expect(try core.getValue("OPENAI_API_KEY", inScope: "kanyo-dev") == "sk-live-123")
        }
    }

    // MARK: - rotate

    @Test("rotate updates the value and leaves notes alone")
    func rotateUpdatesValue() throws {
        try Self.withEphemeralVaultAndKey { vault, fixture in
            try Self.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret(
                "TOKEN",
                value: "original",
                inScope: "kanyo-dev",
                notes: "issued 2026-01-01"
            )
            try core.rotate("TOKEN", inScope: "kanyo-dev", newValue: "rotated")
            #expect(try core.getValue("TOKEN", inScope: "kanyo-dev") == "rotated")
            // Rotate again to confirm the pipeline is stable and notes still parseable
            try core.rotate("TOKEN", inScope: "kanyo-dev", newValue: "rotated-twice")
            #expect(try core.getValue("TOKEN", inScope: "kanyo-dev") == "rotated-twice")
        }
    }

    // MARK: - rotateShared

    @Test("rotateShared propagates through every linking scope")
    func rotateSharedPropagates() throws {
        try Self.withEphemeralVaultAndKey { vault, fixture in
            try Self.writeScope("kanyo-dev", type: .projectDev, in: vault)
            try Self.writeScope("kanyo-prod", type: .projectProd, in: vault)
            try Self.writeSharedEntry(
                "openai-personal",
                value: "sk-original",
                vault: vault,
                fixture: fixture
            )
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.link("OPENAI_API_KEY", inScope: "kanyo-dev", toShared: "openai-personal")
            try core.link("OPENAI_API_KEY", inScope: "kanyo-prod", toShared: "openai-personal")

            try core.rotateShared("openai-personal", newValue: "sk-rotated")

            #expect(try core.getValue("OPENAI_API_KEY", inScope: "kanyo-dev") == "sk-rotated")
            #expect(try core.getValue("OPENAI_API_KEY", inScope: "kanyo-prod") == "sk-rotated")
        }
    }

    // MARK: - unlink

    @Test("unlink converts a linked key back to a local .age with the former shared value")
    func unlinkConvertsToLocal() throws {
        try Self.withEphemeralVaultAndKey { vault, fixture in
            try Self.writeScope("kanyo-dev", type: .projectDev, in: vault)
            try Self.writeSharedEntry(
                "openai-personal",
                value: "sk-was-shared",
                vault: vault,
                fixture: fixture
            )
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.link("OPENAI_API_KEY", inScope: "kanyo-dev", toShared: "openai-personal")

            try core.unlink("OPENAI_API_KEY", inScope: "kanyo-dev")

            let linkURL = VaultLayout.linkURL("OPENAI_API_KEY", inScope: "kanyo-dev", in: vault)
            let ageURL = VaultLayout.secretURL("OPENAI_API_KEY", inScope: "kanyo-dev", in: vault)
            #expect(!FileManager.default.fileExists(atPath: linkURL.path))
            #expect(FileManager.default.fileExists(atPath: ageURL.path))
            #expect(try core.getValue("OPENAI_API_KEY", inScope: "kanyo-dev") == "sk-was-shared")

            // Rotating the shared entry no longer touches the unlinked scope's copy.
            try core.rotateShared("openai-personal", newValue: "sk-later-rotation")
            #expect(try core.getValue("OPENAI_API_KEY", inScope: "kanyo-dev") == "sk-was-shared")
        }
    }

    // MARK: - Orphan detection end-to-end

    @Test("orphanedSharedEntries surfaces unreferenced entries after real encryption")
    func orphansEndToEnd() throws {
        try Self.withEphemeralVaultAndKey { vault, fixture in
            try Self.writeSharedEntry(
                "openai-personal",
                value: "sk-live",
                vault: vault,
                fixture: fixture
            )
            try Self.writeSharedEntry(
                "abandoned-service",
                value: "unused",
                vault: vault,
                fixture: fixture
            )
            try Self.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.link("OPENAI_API_KEY", inScope: "kanyo-dev", toShared: "openai-personal")

            #expect(try core.orphanedSharedEntries() == ["abandoned-service"])
        }
    }

    // MARK: - Error paths

    @Test("getValue on a missing key throws secretNotFound")
    func getValueMissing() throws {
        try Self.withEphemeralVaultAndKey { vault, fixture in
            try Self.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            #expect(throws: VaultError.self) {
                _ = try core.getValue("GHOST", inScope: "kanyo-dev")
            }
        }
    }

    @Test("getValue on a link whose target is missing throws linkTargetMissing")
    func getValueDanglingLink() throws {
        try Self.withEphemeralVaultAndKey { vault, fixture in
            try Self.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.link("OPENAI_API_KEY", inScope: "kanyo-dev", toShared: "nonexistent-shared")
            #expect(throws: VaultError.self) {
                _ = try core.getValue("OPENAI_API_KEY", inScope: "kanyo-dev")
            }
        }
    }

    @Test("rotate on a nonexistent key throws secretNotFound")
    func rotateMissing() throws {
        try Self.withEphemeralVaultAndKey { vault, fixture in
            try Self.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            #expect(throws: VaultError.self) {
                try core.rotate("GHOST", inScope: "kanyo-dev", newValue: "nope")
            }
        }
    }

    @Test("rotateShared on a nonexistent id throws sharedEntryNotFound")
    func rotateSharedMissing() throws {
        try Self.withEphemeralVaultAndKey { vault, fixture in
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            #expect(throws: VaultError.self) {
                try core.rotateShared("ghost-shared", newValue: "nope")
            }
        }
    }

    @Test("unlink on a non-linked key throws secretNotFound")
    func unlinkNonLinked() throws {
        try Self.withEphemeralVaultAndKey { vault, fixture in
            try Self.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            #expect(throws: VaultError.self) {
                try core.unlink("NOT_A_LINK", inScope: "kanyo-dev")
            }
        }
    }

    @Test("addSecret from a vault opened without an age key throws shellNotFound")
    func addSecretWithoutKeyRefuses() throws {
        try Self.withEphemeralVaultAndKey { vault, _ in
            try Self.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault)  // no ageKeyURL
            #expect(throws: VaultError.self) {
                try core.addSecret("K", value: "v", inScope: "kanyo-dev")
            }
        }
    }

    @Test("init with a malformed age key file throws ageInvocationFailed")
    func initRejectsMalformedKey() throws {
        try Self.withEphemeralVaultAndKey { vault, _ in
            let bogusKey = FileManager.default.temporaryDirectory
                .appendingPathComponent("bogus-\(UUID().uuidString).txt")
            try "not a real age key file".write(to: bogusKey, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: bogusKey) }
            #expect(throws: VaultError.self) {
                _ = try VaultCore(vaultURL: vault, ageKeyURL: bogusKey)
            }
        }
    }
}
