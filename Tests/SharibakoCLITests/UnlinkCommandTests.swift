import Foundation
import Testing

@testable import SharibakoCLI
@testable import SharibakoCore

@Suite("UnlinkCommand")
struct UnlinkCommandTests {
    @Test("converts a link into a scope-local secret")
    func unlinkHappyPath() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            try vault.addSharedEntry("shared-db", value: "the-value")
            try vault.link("DB_URL", inScope: "s1", toShared: "shared-db")

            var cmd = try UnlinkCommand.parse([
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
                "s1", "DB_URL",
            ])
            try cmd._run()

            let newVault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            let infos = try newVault.inspect("s1")
            let info = infos.first { $0.key == "DB_URL" }
            #expect(info?.kind == .value)
            #expect((try? newVault.getValue("DB_URL", inScope: "s1")) == "the-value")
        }
    }

    @Test("unlink via run(): succeeds end-to-end without exiting")
    func unlinkRunShim() async throws {
        try await CLITestSupport.withEphemeralVaultAndFileKeyAsync { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            try vault.addSharedEntry("shared-db", value: "the-value")
            try vault.link("DB_URL", inScope: "s1", toShared: "shared-db")

            try await CLITestSupport.runCommand([
                "unlink",
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
                "s1", "DB_URL",
            ])

            let newVault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            let info = try newVault.inspect("s1").first { $0.key == "DB_URL" }
            #expect(info?.kind == .value)
        }
    }

    @Test("_run throws secretNotFound when no link exists at the key")
    func unlinkMissingLink() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            var cmd = try UnlinkCommand.parse([
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
                "s1", "NO_LINK",
            ])
            #expect(throws: VaultError.self) {
                try cmd._run()
            }
        }
    }
}
