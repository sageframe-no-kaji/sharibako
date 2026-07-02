import Foundation
import Testing

@testable import SharibakoCLI
@testable import SharibakoCore

@Suite("AddCommand")
struct AddCommandTests {
    @Test("adds a new secret via --value flag")
    func addHappyPath() async throws {
        try await CLITestSupport.withEphemeralVaultAndFileKeyAsync { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            try await CLITestSupport.runCommand([
                "add",
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
                "s1", "API_KEY", "--value", "my-secret",
            ])
            let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            let value = try vault.getValue("API_KEY", inScope: "s1")
            #expect(value == "my-secret")
        }
    }

    @Test("_run stores notes when --notes is supplied")
    func addWithNotes() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            var cmd = try AddCommand.parse([
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
                "--value", "v1",
                "--notes", "production key",
                "s1", "K",
            ])
            try cmd._run()
            let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            #expect((try? vault.getValue("K", inScope: "s1")) == "v1")
        }
    }

    @Test("_run throws secretAlreadyExists when key exists without --force")
    func addRefusesOverwrite() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            try vault.addSecret("K", value: "v1", inScope: "s1")

            var cmd = try AddCommand.parse([
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
                "--value", "v2",
                "s1", "K",
            ])
            #expect(throws: CLIError.secretAlreadyExists(scope: "s1", key: "K")) {
                try cmd._run()
            }
        }
    }

    @Test("_run with --force overwrites existing key")
    func addWithForceOverwrites() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            try vault.addSecret("K", value: "v1", inScope: "s1")

            var cmd = try AddCommand.parse([
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
                "--value", "v2",
                "--force",
                "s1", "K",
            ])
            try cmd._run()
            let newVault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            #expect((try? newVault.getValue("K", inScope: "s1")) == "v2")
        }
    }

    @Test("_run throws scopeNotFound for missing scope")
    func addFailsMissingScope() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            var cmd = try AddCommand.parse([
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
                "--value", "v",
                "no-such-scope", "K",
            ])
            #expect(throws: VaultError.self) {
                try cmd._run()
            }
        }
    }

    @Test("_run throws valueInputConflict when both --value and --from-stdin are set")
    func addConflictingInput() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            var cmd = try AddCommand.parse([
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
                "--value", "v",
                "--from-stdin",
                "s1", "K",
            ])
            #expect(throws: CLIError.valueInputConflict) {
                try cmd._run()
            }
        }
    }

    @Test("_run throws valueInputRequired when neither input flag is set")
    func addMissingInput() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            var cmd = try AddCommand.parse([
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
                "s1", "K",
            ])
            #expect(throws: CLIError.valueInputRequired) {
                try cmd._run()
            }
        }
    }
}
