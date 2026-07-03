import Foundation
import Testing

@testable import SharibakoCLI
@testable import SharibakoCore

@Suite("RotateCommand")
struct RotateCommandTests {
    @Test("rotates a scope-local secret to the new value")
    func rotateLocalKey() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            try vault.addSecret("K", value: "old", inScope: "s1")

            var cmd = try RotateCommand.parse([
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
                "--value", "new",
                "s1", "K",
            ])
            try cmd._run()

            let newVault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            #expect((try? newVault.getValue("K", inScope: "s1")) == "new")
        }
    }

    @Test("rotating a linked key rotates the shared entry")
    func rotateViaLink() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            try vault.addSharedEntry("shared-db", value: "old-shared")
            try vault.link("DB_URL", inScope: "s1", toShared: "shared-db")

            var cmd = try RotateCommand.parse([
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
                "--value", "new-shared",
                "s1", "DB_URL",
            ])
            try cmd._run()

            let newVault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            #expect((try? newVault.getValue("DB_URL", inScope: "s1")) == "new-shared")
        }
    }

    @Test("rotate via run(): succeeds end-to-end without exiting")
    func rotateRunShim() async throws {
        try await CLITestSupport.withEphemeralVaultAndFileKeyAsync { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            try vault.addSecret("K", value: "old", inScope: "s1")

            try await CLITestSupport.runCommand([
                "rotate",
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
                "--value", "rotated-via-run",
                "s1", "K",
            ])

            let newVault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            #expect((try? newVault.getValue("K", inScope: "s1")) == "rotated-via-run")
        }
    }

    @Test("_run throws secretNotFound for an unknown key")
    func rotateUnknownKey() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            var cmd = try RotateCommand.parse([
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
                "--value", "v",
                "s1", "NO_SUCH_KEY",
            ])
            #expect(throws: VaultError.self) {
                try cmd._run()
            }
        }
    }

    @Test("_run throws valueInputConflict when both input flags set")
    func rotateConflictingInput() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            var cmd = try RotateCommand.parse([
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

    // MARK: - rotate --shared (ho-04.10)

    @Test("rotate --shared rotates a shared entry no scope links")
    func rotateSharedDirect() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            try vault.addSharedEntry("zero-links", value: "old")

            var cmd = try RotateCommand.parse([
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
                "--value", "new",
                "--shared", "zero-links",
            ])
            try cmd._run()

            // Verify through a fresh link — the only read path for a shared entry.
            try CLITestSupport.writeScope("probe", in: vaultURL)
            let newVault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            try newVault.link("K", inScope: "probe", toShared: "zero-links")
            #expect((try? newVault.getValue("K", inScope: "probe")) == "new")
        }
    }

    @Test("rotate --shared throws sharedEntryNotFound for an unknown entry")
    func rotateSharedUnknown() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            var cmd = try RotateCommand.parse([
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
                "--value", "v",
                "--shared", "ghost",
            ])
            #expect(throws: VaultError.self) {
                try cmd._run()
            }
        }
    }

    @Test("--shared is mutually exclusive with scope/key; one form is required")
    func rotateSharedExclusivity() {
        #expect(throws: (any Error).self) {
            _ = try RotateCommand.parse(["--value", "v", "--shared", "x", "s1", "K"])
        }
        #expect(throws: (any Error).self) {
            _ = try RotateCommand.parse(["--value", "v"])
        }
        #expect(throws: (any Error).self) {
            _ = try RotateCommand.parse(["--value", "v", "s1"])
        }
    }
}
