import Foundation
import Testing

@testable import SharibakoCLI
@testable import SharibakoCore

@Suite("GetCommand")
struct GetCommandTests {
    @Test("fetchValue returns the decrypted value")
    func fetchValueHappyPath() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            try vault.addSecret("API_KEY", value: "secret-value", inScope: "s1")

            var cmd = try GetCommand.parse([
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
                "s1", "API_KEY",
            ])
            let value = try cmd.fetchValue()
            #expect(value == "secret-value")
        }
    }

    @Test("fetchValue resolves a linked key through the shared entry")
    func fetchValueViaLink() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            try vault.addSharedEntry("shared-db", value: "shared-secret")
            try vault.link("DB_URL", inScope: "s1", toShared: "shared-db")

            var cmd = try GetCommand.parse([
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
                "s1", "DB_URL",
            ])
            let value = try cmd.fetchValue()
            #expect(value == "shared-secret")
        }
    }

    @Test("_run throws secretNotFound for missing key")
    func runThrowsForMissingKey() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)

            var cmd = try GetCommand.parse([
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
                "s1", "MISSING",
            ])
            #expect(throws: (any Error).self) {
                try cmd._run()
            }
        }
    }

    @Test("_run throws scopeNotFound for unknown scope")
    func runThrowsForUnknownScope() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            var cmd = try GetCommand.parse([
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
                "no-such-scope", "KEY",
            ])
            #expect(throws: (any Error).self) {
                try cmd._run()
            }
        }
    }
}
