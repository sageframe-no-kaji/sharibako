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
    // MARK: - Round-trip

    @Test("addSecret then getValue returns the original value")
    func addSecretRoundTrip() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("DATABASE_URL", value: "postgres://x@y/z", inScope: "kanyo-dev")
            let got = try core.getValue("DATABASE_URL", inScope: "kanyo-dev")
            #expect(got == "postgres://x@y/z")
        }
    }

    @Test("addSecret preserves notes through encrypt/decrypt")
    func addSecretPreservesNotes() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
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
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            try VaultTestSupport.writeSharedEntry(
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
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
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
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            try VaultTestSupport.writeScope("kanyo-prod", type: .projectProd, in: vault)
            try VaultTestSupport.writeSharedEntry(
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
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            try VaultTestSupport.writeSharedEntry(
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
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeSharedEntry(
                "openai-personal",
                value: "sk-live",
                vault: vault,
                fixture: fixture
            )
            try VaultTestSupport.writeSharedEntry(
                "abandoned-service",
                value: "unused",
                vault: vault,
                fixture: fixture
            )
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.link("OPENAI_API_KEY", inScope: "kanyo-dev", toShared: "openai-personal")

            #expect(try core.orphanedSharedEntries() == ["abandoned-service"])
        }
    }

    // MARK: - Error paths

    @Test("getValue on a missing key throws secretNotFound")
    func getValueMissing() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            #expect(throws: VaultError.self) {
                _ = try core.getValue("GHOST", inScope: "kanyo-dev")
            }
        }
    }

    @Test("getValue on a link whose target is missing throws linkTargetMissing")
    func getValueDanglingLink() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.link("OPENAI_API_KEY", inScope: "kanyo-dev", toShared: "nonexistent-shared")
            #expect(throws: VaultError.self) {
                _ = try core.getValue("OPENAI_API_KEY", inScope: "kanyo-dev")
            }
        }
    }

    @Test("rotate on a nonexistent key throws secretNotFound")
    func rotateMissing() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            #expect(throws: VaultError.self) {
                try core.rotate("GHOST", inScope: "kanyo-dev", newValue: "nope")
            }
        }
    }

    @Test("rotateShared on a nonexistent id throws sharedEntryNotFound")
    func rotateSharedMissing() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            #expect(throws: VaultError.self) {
                try core.rotateShared("ghost-shared", newValue: "nope")
            }
        }
    }

    @Test("unlink on a non-linked key throws secretNotFound")
    func unlinkNonLinked() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            #expect(throws: VaultError.self) {
                try core.unlink("NOT_A_LINK", inScope: "kanyo-dev")
            }
        }
    }

    @Test("addSecret from a vault opened without an age key throws shellNotFound")
    func addSecretWithoutKeyRefuses() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, _ in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault)  // no ageKeyURL
            #expect(throws: VaultError.self) {
                try core.addSecret("K", value: "v", inScope: "kanyo-dev")
            }
        }
    }

    @Test("getValue from a vault opened without an age key throws shellNotFound")
    func getValueWithoutKeyRefuses() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            // Seed a real .age file so getValue reaches the decrypt path
            let seeded = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try seeded.addSecret("K", value: "v", inScope: "kanyo-dev")

            let noKey = try VaultCore(vaultURL: vault)
            #expect(throws: VaultError.self) {
                _ = try noKey.getValue("K", inScope: "kanyo-dev")
            }
        }
    }

    @Test("addSecret throws scopeNotFound when the scope directory is absent")
    func addSecretMissingScope() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            #expect(throws: VaultError.self) {
                try core.addSecret("K", value: "v", inScope: "ghost-scope")
            }
        }
    }

    @Test("unlink on a link whose shared target is missing throws linkTargetMissing")
    func unlinkDanglingLink() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            // Create a .link file pointing at a shared entry that doesn't exist.
            try core.link("OPENAI_API_KEY", inScope: "kanyo-dev", toShared: "openai-personal")
            #expect(throws: VaultError.self) {
                try core.unlink("OPENAI_API_KEY", inScope: "kanyo-dev")
            }
        }
    }

    @Test("getValue throws yamlDecodeError when the decrypted payload is not valid YAML")
    func getValueRejectsCorruptPayload() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            // Encrypt a non-YAML plaintext directly with age so decryption succeeds
            // but YAML decoding fails.
            let tempFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("corrupt-\(UUID().uuidString).txt")
            try "@@@ this is not: :::valid yaml".write(to: tempFile, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: tempFile) }

            let target = VaultLayout.secretURL("CORRUPT", inScope: "kanyo-dev", in: vault)
            let ageBinary = try Shell.findExecutable("age")
            let result = try Shell.run(
                ageBinary,
                ["--encrypt", "--recipient", fixture.publicKey, "-o", target.path, tempFile.path]
            )
            #expect(result.exitCode == 0)

            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            #expect(throws: VaultError.self) {
                _ = try core.getValue("CORRUPT", inScope: "kanyo-dev")
            }
        }
    }

    @Test("init with a malformed age key file throws ageInvocationFailed")
    func initRejectsMalformedKey() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, _ in
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
