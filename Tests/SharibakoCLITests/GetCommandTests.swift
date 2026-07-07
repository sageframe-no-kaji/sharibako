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

            let cmd = try GetCommand.parse([
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

            let cmd = try GetCommand.parse([
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

            let cmd = try GetCommand.parse([
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
                "s1", "MISSING",
            ])
            #expect(throws: (any Error).self) {
                try cmd._run()
            }
        }
    }

    @Test("get via run(): prints the decrypted value without exiting")
    func getRunShim() async throws {
        try await CLITestSupport.withEphemeralVaultAndFileKeyAsync { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            try vault.addSecret("API_KEY", value: "run-shim-value", inScope: "s1")

            // Success path through run(): no ErrorReporter, no Foundation.exit.
            try await CLITestSupport.runCommand([
                "get",
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
                "s1", "API_KEY",
            ])
        }
    }

    @Test("_run throws scopeNotFound for unknown scope")
    func runThrowsForUnknownScope() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            let cmd = try GetCommand.parse([
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
