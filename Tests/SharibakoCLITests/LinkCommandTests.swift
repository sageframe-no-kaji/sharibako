import Foundation
import Testing

@testable import SharibakoCLI
@testable import SharibakoCore

@Suite("LinkCommand")
struct LinkCommandTests {
    @Test("links a scope key to an existing shared entry")
    func linkHappyPath() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            try vault.addSharedEntry("shared-db", value: "shared-value")

            let cmd = try LinkCommand.parse([
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
                "s1", "DB_URL", "shared-db",
            ])
            try cmd._run()

            let infos = try vault.inspect("s1")
            let linkInfo = infos.first { $0.key == "DB_URL" }
            guard let linkInfo else {
                Issue.record("DB_URL not found in scope")
                return
            }
            if case .link(let sharedID) = linkInfo.kind {
                #expect(sharedID == "shared-db")
            } else {
                Issue.record("Expected .link kind")
            }
        }
    }

    @Test("link via run(): succeeds end-to-end without exiting")
    func linkRunShim() async throws {
        try await CLITestSupport.withEphemeralVaultAndFileKeyAsync { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            try vault.addSharedEntry("shared-db", value: "shared-value")

            try await CLITestSupport.runCommand([
                "link",
                "--vault", vaultURL.path,
                "s1", "DB_URL", "shared-db",
            ])

            let infos = try vault.inspect("s1")
            #expect(infos.contains { $0.key == "DB_URL" })
        }
    }

    @Test("_run throws sharedEntryNotFound for unknown shared entry")
    func linkMissingSharedEntry() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            let cmd = try LinkCommand.parse([
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
                "s1", "K", "no-such-shared",
            ])
            #expect(throws: VaultError.self) {
                try cmd._run()
            }
        }
    }

    @Test("link does not require the age key")
    func linkDoesNotNeedAgeKey() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            try vault.addSharedEntry("shared-db", value: "v")

            // Supply no --age-key: the command should succeed without decrypting anything.
            // (The vault layout exists, so VaultCore(vaultURL:) succeeds.)
            let cmd = try LinkCommand.parse([
                "--vault", vaultURL.path,
                "s1", "DB_URL", "shared-db",
            ])
            try cmd._run()
            let infos = try vault.inspect("s1")
            #expect(infos.contains { $0.key == "DB_URL" })
        }
    }
}
