import Foundation
import Testing

@testable import SharibakoCLI
@testable import SharibakoCore

/// Tests for `DeleteCommand` — scope and shared-entry deletion, the
/// confirmation gate (like `clean`), and the linked-shared guard (ho-06.7).
@Suite("DeleteCommand")
struct DeleteCommandTests {
    // MARK: - Scope deletion

    @Test("delete <scope> --yes removes the scope")
    func deleteScopeWithYes() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            try CLITestSupport.writeScope("s2", in: vaultURL)

            let cmd = try DeleteCommand.parse(["--vault", vaultURL.path, "--yes", "s1"])
            try cmd._run()

            let vault = try VaultCore(vaultURL: vaultURL)
            #expect(try vault.listScopes().map(\.identity) == ["s2"])
        }
    }

    @Test("delete <absent> throws scopeNotFound")
    func deleteAbsentScope() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            let cmd = try DeleteCommand.parse(["--vault", vaultURL.path, "--yes", "ghost"])
            let error = #expect(throws: VaultError.self) { try cmd._run() }
            guard case .scopeNotFound(let id) = error else {
                Issue.record("expected scopeNotFound, got \(String(describing: error))")
                return
            }
            #expect(id == "ghost")
        }
    }

    // MARK: - Confirmation gate

    @Test("confirmation: 'n' aborts and deletes nothing")
    func confirmationDeclineAborts() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            try CLITestSupport.writeScope("s1", in: vaultURL)

            let cmd = try DeleteCommand.parse(["--vault", vaultURL.path, "s1"])
            #expect(throws: CLIError.self) {
                try cmd._run(isInteractive: true) { "n" }
            }
            let vault = try VaultCore(vaultURL: vaultURL)
            #expect(try vault.listScopes().map(\.identity) == ["s1"])
        }
    }

    @Test("non-TTY without --yes throws promptRequiresTTY and deletes nothing")
    func nonTTYRequiresYes() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            try CLITestSupport.writeScope("s1", in: vaultURL)

            let cmd = try DeleteCommand.parse(["--vault", vaultURL.path, "s1"])
            #expect(throws: CLIError.self) {
                try cmd._run(isInteractive: false) { nil }
            }
            let vault = try VaultCore(vaultURL: vaultURL)
            #expect(try vault.listScopes().map(\.identity) == ["s1"])
        }
    }

    // MARK: - Shared-entry deletion

    @Test("delete --shared <id> --yes removes an unlinked entry")
    func deleteSharedUnlinked() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            try vault.addSharedEntry("openai-personal", value: "sk-x")

            let cmd = try DeleteCommand.parse([
                "--vault", vaultURL.path, "--shared", "--yes", "openai-personal",
            ])
            try cmd._run()

            #expect(try VaultCore(vaultURL: vaultURL).listShared().isEmpty)
        }
    }

    @Test("delete --shared of a linked entry is refused without --force")
    func deleteSharedLinkedRefused() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            try vault.addSharedEntry("openai-personal", value: "sk-x")
            try vault.link("OPENAI_API_KEY", inScope: "s1", toShared: "openai-personal")

            let cmd = try DeleteCommand.parse([
                "--vault", vaultURL.path, "--shared", "--yes", "openai-personal",
            ])
            let error = #expect(throws: VaultError.self) { try cmd._run() }
            guard case .sharedEntryLinked(let id, let linkers) = error else {
                Issue.record("expected sharedEntryLinked, got \(String(describing: error))")
                return
            }
            #expect(id == "openai-personal")
            #expect(linkers.first?.scopeID == "s1")
            // Refused means the entry is still present.
            #expect(try VaultCore(vaultURL: vaultURL).listShared() == ["openai-personal"])
        }
    }

    @Test("delete --shared --force removes a linked entry and orphans the linker")
    func deleteSharedForced() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            try vault.addSharedEntry("openai-personal", value: "sk-x")
            try vault.link("OPENAI_API_KEY", inScope: "s1", toShared: "openai-personal")

            let cmd = try DeleteCommand.parse([
                "--vault", vaultURL.path, "--shared", "--force", "--yes", "openai-personal",
            ])
            try cmd._run()

            #expect(try VaultCore(vaultURL: vaultURL).listShared().isEmpty)
            // The link is left dangling for the orphan/heal surfaces.
            let linkURL = try VaultLayout.linkURL("OPENAI_API_KEY", inScope: "s1", in: vaultURL)
            #expect(FileManager.default.fileExists(atPath: linkURL.path))
        }
    }
}
