import Foundation
import Testing

@testable import SharibakoCLI
@testable import SharibakoCore

/// The `delete` verb's remaining surfaces: the two confirmation prompts the
/// scope-deletion suite does not reach (shared entry, single key) and the
/// `--json` success path for all three targets.
///
/// Keyless throughout — deletion removes files and never decrypts.
@Suite("DeleteCommand prompts and JSON")
struct DeleteCommandPromptAndJSONTests {
    // MARK: - Confirmation prompts

    @Test("confirming a shared-entry deletion at the prompt removes it")
    func sharedPromptAccepted() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            try vault.addSharedEntry("ANTHROPIC", value: "sk-test")

            let cmd = try DeleteCommand.parse(["--vault", vaultURL.path, "--shared", "ANTHROPIC"])
            try cmd._run(isInteractive: true) { "y" }

            #expect(try VaultCore(vaultURL: vaultURL).listShared().isEmpty)
        }
    }

    @Test("declining a shared-entry deletion at the prompt keeps it")
    func sharedPromptDeclined() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            try vault.addSharedEntry("ANTHROPIC", value: "sk-test")

            let cmd = try DeleteCommand.parse(["--vault", vaultURL.path, "--shared", "ANTHROPIC"])
            #expect(throws: CLIError.self) { try cmd._run(isInteractive: true) { "n" } }

            #expect(try VaultCore(vaultURL: vaultURL).listShared().count == 1)
        }
    }

    @Test("confirming a single-key deletion at the prompt removes just that key")
    func keyPromptAccepted() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            try vault.addSecret("DB", value: "postgres://x", inScope: "s1")
            try vault.addSecret("API", value: "sk-y", inScope: "s1")

            let cmd = try DeleteCommand.parse(["--vault", vaultURL.path, "s1", "DB"])
            try cmd._run(isInteractive: true) { "yes" }

            #expect(try VaultCore(vaultURL: vaultURL).inspect("s1").map(\.key) == ["API"])
        }
    }

    @Test("declining a single-key deletion at the prompt keeps it")
    func keyPromptDeclined() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            try vault.addSecret("DB", value: "postgres://x", inScope: "s1")

            let cmd = try DeleteCommand.parse(["--vault", vaultURL.path, "s1", "DB"])
            #expect(throws: CLIError.self) { try cmd._run(isInteractive: true) { "n" } }

            #expect(try VaultCore(vaultURL: vaultURL).inspect("s1").map(\.key) == ["DB"])
        }
    }

    // MARK: - JSON success path

    @Test("--json deletes the scope and renders the JSON payload")
    func jsonScope() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            try CLITestSupport.writeScope("s1", in: vaultURL)

            let cmd = try DeleteCommand.parse(["--vault", vaultURL.path, "--json", "--yes", "s1"])
            try cmd._run()

            #expect(try VaultCore(vaultURL: vaultURL).listScopes().isEmpty)
        }
    }

    @Test("--json deletes the key and renders the scope/key payload")
    func jsonKey() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            try vault.addSecret("DB", value: "postgres://x", inScope: "s1")

            let cmd = try DeleteCommand.parse(
                ["--vault", vaultURL.path, "--json", "--yes", "s1", "DB"])
            try cmd._run()

            #expect(try VaultCore(vaultURL: vaultURL).inspect("s1").isEmpty)
        }
    }

    @Test("--json deletes the shared entry and renders the JSON payload")
    func jsonShared() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            try vault.addSharedEntry("ANTHROPIC", value: "sk-test")

            let cmd = try DeleteCommand.parse(
                ["--vault", vaultURL.path, "--json", "--yes", "--shared", "ANTHROPIC"])
            try cmd._run()

            #expect(try VaultCore(vaultURL: vaultURL).listShared().isEmpty)
        }
    }
}
