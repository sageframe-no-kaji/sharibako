import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

// MARK: - Test support

/// Generates an ephemeral age key pair in a temp directory using `age-keygen`.
///
/// Returns the private-key URL and cleans up in `body`'s defer block.
private func withEphemeralAgeKey(_ body: (URL) throws -> Void) throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sharibako-apptest-key-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let keyURL = tempDir.appendingPathComponent("age-key.txt")
    let ageKeygenURL = try Shell.findExecutable("age-keygen")
    let result = try Shell.run(ageKeygenURL, ["-o", keyURL.path])
    guard result.exitCode == 0 else {
        throw VaultError.ageInvocationFailed(exitCode: result.exitCode, stderr: result.stderr)
    }
    try body(keyURL)
}

/// Materialises a temp vault with vault layout + git init + identity, and calls `body`.
private func withGitVault(_ body: (URL) throws -> Void) throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sharibako-apptest-vault-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try VaultLayout.createVaultLayout(at: tempDir)
    let conduit = try Conduit(vaultURL: tempDir)
    try conduit.initializeRepository()
    try conduit.setIdentity(name: "AppTests", email: "app@example.invalid")
    try body(tempDir)
}

// MARK: - WorkshopModel AT-02 tests

/// `WorkshopModel` AT-02 tests: secret listing, reveal state machine, history.
///
/// All tests use the file-key dev path via `SHARIBAKO_AGE_KEY` — no Keychain,
/// no signing required.
@MainActor
@Suite("WorkshopModel AT-02")
struct WorkshopModelRevealTests {
    // MARK: - Secret listing

    @Test("loadSecrets populates the secrets array for a scope with files")
    func loadSecretsPopulatesArray() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("myScope", type: .other, in: vault)

            // Write a placeholder .age file directly (no encryption needed for inspect).
            let scopeDir =
                vault
                .appendingPathComponent("scopes")
                .appendingPathComponent("myScope")
            try Data([0x00]).write(
                to: scopeDir.appendingPathComponent("API_KEY.age"))

            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.selectedScopeID = "myScope"
            model.loadSecrets(for: "myScope")

            #expect(model.secrets.count == 1)
            #expect(model.secrets[0].key == "API_KEY")
            #expect(model.secrets[0].kind == .value)
        }
    }

    @Test("loadSecrets includes .link entries with their sharedID")
    func loadSecretsIncludesLinks() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("linked", type: .other, in: vault)
            let scopeDir =
                vault
                .appendingPathComponent("scopes")
                .appendingPathComponent("linked")
            // Write a .link file (no shared entry needed for inspect-only listing).
            try "shared-db".write(
                to: scopeDir.appendingPathComponent("DB_URL.link"),
                atomically: true,
                encoding: .utf8
            )

            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.selectedScopeID = "linked"
            model.loadSecrets(for: "linked")

            #expect(model.secrets.count == 1)
            #expect(model.secrets[0].key == "DB_URL")
            #expect(model.secrets[0].kind == .link(sharedID: "shared-db"))
        }
    }

    @Test("Selecting a different scope clears secrets and revealedValue")
    func scopeChangeClearsState() throws {
        try WorkshopTestSupport.withTempVault { vault in
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            // Set a scope and selection, then change scope to verify reset.
            model.selectedScopeID = "scope-a"
            model.selectedSecretKey = "OLD_KEY"
            model.selectedScopeID = "scope-b"
            #expect(model.selectedSecretKey == nil)
            #expect(model.revealedValue == nil)
        }
    }

    @Test("Selecting a different secret clears revealedValue")
    func secretChangeClearsReveal() throws {
        try WorkshopTestSupport.withTempVault { vault in
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.selectedScopeID = "myScope"
            model.selectedSecretKey = "KEY_A"
            model.selectedSecretKey = "KEY_B"
            #expect(model.revealedValue == nil)
        }
    }

    // MARK: - Reveal with file-key path

    @Test("reveal yields the known plaintext via the file-key dev path")
    func revealWithFileKey() throws {
        try withEphemeralAgeKey { keyURL in
            try WorkshopTestSupport.withTempVault { vault in
                // Write a real scope and encrypt a known secret into it.
                try WorkshopTestSupport.writeScope("dev-scope", type: .other, in: vault)
                let core = try VaultCore(vaultURL: vault, ageKeyURL: keyURL)
                try core.addSecret("MY_TOKEN", value: "hunter2", inScope: "dev-scope")

                let model = WorkshopModel(
                    environment: [
                        "SHARIBAKO_VAULT": vault.path,
                        "SHARIBAKO_AGE_KEY": keyURL.path,
                    ],
                    home: URL(fileURLWithPath: "/Users/nobody")
                )
                model.selectedScopeID = "dev-scope"
                model.loadSecrets(for: "dev-scope")
                model.selectedSecretKey = "MY_TOKEN"

                model.reveal(key: "MY_TOKEN", inScope: "dev-scope")

                #expect(model.revealedValue == "hunter2")
                #expect(model.errorMessage == nil)
            }
        }
    }

    @Test("reveal clears errorMessage on success")
    func revealClearsError() throws {
        try withEphemeralAgeKey { keyURL in
            try WorkshopTestSupport.withTempVault { vault in
                try WorkshopTestSupport.writeScope("err-scope", type: .other, in: vault)
                let core = try VaultCore(vaultURL: vault, ageKeyURL: keyURL)
                try core.addSecret("MY_KEY", value: "secret-value", inScope: "err-scope")

                let model = WorkshopModel(
                    environment: [
                        "SHARIBAKO_VAULT": vault.path,
                        "SHARIBAKO_AGE_KEY": keyURL.path,
                    ],
                    home: URL(fileURLWithPath: "/Users/nobody")
                )
                model.errorMessage = "stale error"
                model.selectedScopeID = "err-scope"
                model.selectedSecretKey = "MY_KEY"

                model.reveal(key: "MY_KEY", inScope: "err-scope")

                #expect(model.errorMessage == nil)
            }
        }
    }

    @Test("reveal with a missing key file surfaces an errorMessage")
    func revealMissingKeyFileSurfacesError() throws {
        try WorkshopTestSupport.withTempVault { vault in
            let model = WorkshopModel(
                environment: [
                    "SHARIBAKO_VAULT": vault.path,
                    "SHARIBAKO_AGE_KEY": "/tmp/nonexistent-key-\(UUID().uuidString).txt",
                ],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.selectedScopeID = "scope"
            model.selectedSecretKey = "KEY"

            model.reveal(key: "KEY", inScope: "scope")

            // Key file does not exist → provider throws → errorMessage set.
            #expect(model.revealedValue == nil)
            #expect(model.errorMessage != nil)
        }
    }

    @Test("maskValue clears revealedValue without changing selection")
    func maskValueClearsReveal() throws {
        try withEphemeralAgeKey { keyURL in
            try WorkshopTestSupport.withTempVault { vault in
                try WorkshopTestSupport.writeScope("mask-scope", type: .other, in: vault)
                let core = try VaultCore(vaultURL: vault, ageKeyURL: keyURL)
                try core.addSecret("TOKEN", value: "visible", inScope: "mask-scope")

                let model = WorkshopModel(
                    environment: [
                        "SHARIBAKO_VAULT": vault.path,
                        "SHARIBAKO_AGE_KEY": keyURL.path,
                    ],
                    home: URL(fileURLWithPath: "/Users/nobody")
                )
                model.selectedScopeID = "mask-scope"
                model.selectedSecretKey = "TOKEN"
                model.reveal(key: "TOKEN", inScope: "mask-scope")

                #expect(model.revealedValue == "visible")

                model.maskValue()
                #expect(model.revealedValue == nil)
                // Selection unchanged.
                #expect(model.selectedSecretKey == "TOKEN")
            }
        }
    }

    // MARK: - History

    @Test("loadHistory returns commits for a tracked secret file")
    func loadHistoryTrackedFile() throws {
        try withGitVault { vault in
            let conduit = try Conduit(vaultURL: vault)
            try WorkshopTestSupport.writeScope("hist-scope", type: .other, in: vault)
            _ = try conduit.commit(message: "add scope")

            // Write an .age placeholder and commit.
            let scopeDir =
                vault
                .appendingPathComponent("scopes")
                .appendingPathComponent("hist-scope")
            let agePath = scopeDir.appendingPathComponent("HIS_KEY.age")
            try Data([0x00, 0x01]).write(to: agePath)
            _ = try conduit.commit(message: "add HIS_KEY")

            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.selectedScopeID = "hist-scope"
            model.loadHistory(for: "HIS_KEY", inScope: "hist-scope", kind: .value)

            #expect(!model.history.isEmpty)
            #expect(model.history[0].subject == "add HIS_KEY")
        }
    }

    @Test("loadHistory returns [] for an untracked file (no git history)")
    func loadHistoryUntrackedFile() throws {
        try WorkshopTestSupport.withTempVault { vault in
            // No git init — not a git repo.
            try WorkshopTestSupport.writeScope("no-hist", type: .other, in: vault)
            let scopeDir =
                vault
                .appendingPathComponent("scopes")
                .appendingPathComponent("no-hist")
            try Data([0x00]).write(to: scopeDir.appendingPathComponent("NOHIST.age"))

            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.selectedScopeID = "no-hist"
            // Vault is not a git repo; loadHistory should degrade gracefully.
            model.loadHistory(for: "NOHIST", inScope: "no-hist", kind: .value)

            // Either empty history or an errorMessage — not a crash.
            #expect(model.history.isEmpty)
        }
    }

    // MARK: - Error branches

    @Test("loadSecrets surfaces errorMessage when inspect throws (nonexistent scope)")
    func loadSecretsThrowsSetsError() throws {
        try WorkshopTestSupport.withTempVault { vault in
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.selectedScopeID = "ghost-scope"
            model.loadSecrets(for: "ghost-scope")
            // inspect throws scopeNotFound → cachedSecrets cleared, errorMessage set.
            #expect(model.secrets.isEmpty)
            #expect(model.errorMessage != nil)
        }
    }

    @Test("reveal surfaces errorMessage when getValue fails (missing secret file)")
    func revealValueErrorSetsMessage() throws {
        try withEphemeralAgeKey { keyURL in
            try WorkshopTestSupport.withTempVault { vault in
                // Scope exists but secret file does not — getValue throws.
                try WorkshopTestSupport.writeScope("reveal-err", type: .other, in: vault)

                let model = WorkshopModel(
                    environment: [
                        "SHARIBAKO_VAULT": vault.path,
                        "SHARIBAKO_AGE_KEY": keyURL.path,
                    ],
                    home: URL(fileURLWithPath: "/Users/nobody")
                )
                model.selectedScopeID = "reveal-err"
                model.selectedSecretKey = "MISSING_KEY"

                model.reveal(key: "MISSING_KEY", inScope: "reveal-err")

                // Provider succeeds; getValue throws secretNotFound.
                #expect(model.revealedValue == nil)
                #expect(model.errorMessage != nil)
            }
        }
    }

    @Test("loadHistory for a .link file uses the .link path, not .age")
    func loadHistoryForLinkKind() throws {
        try withGitVault { vault in
            let conduit = try Conduit(vaultURL: vault)
            try WorkshopTestSupport.writeScope("link-hist", type: .other, in: vault)
            _ = try conduit.commit(message: "add scope")

            let scopeDir =
                vault
                .appendingPathComponent("scopes")
                .appendingPathComponent("link-hist")
            let linkPath = scopeDir.appendingPathComponent("DB_URL.link")
            try "shared-db".write(to: linkPath, atomically: true, encoding: .utf8)
            _ = try conduit.commit(message: "add DB_URL link")

            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.selectedScopeID = "link-hist"
            model.loadHistory(
                for: "DB_URL", inScope: "link-hist", kind: .link(sharedID: "shared-db"))

            #expect(!model.history.isEmpty)
            #expect(model.history[0].subject == "add DB_URL link")
        }
    }
}

/// Notes-reveal tests, split from `WorkshopModelRevealTests` for suite size.
///
/// Notes travel inside the same encrypted payload as the value, so the reveal
/// path must surface them together (dogfood-gate finding: notes were decrypted
/// and discarded, never displayed).
@MainActor
@Suite("WorkshopModel notes reveal")
struct WorkshopModelNotesRevealTests {
    @Test("reveal populates revealedNotes alongside the value")
    func revealPopulatesNotes() throws {
        try withEphemeralAgeKey { keyURL in
            try WorkshopTestSupport.withTempVault { vault in
                try WorkshopTestSupport.writeScope("notes-scope", type: .other, in: vault)
                let core = try VaultCore(vaultURL: vault, ageKeyURL: keyURL)
                try core.addSecret(
                    "TOKEN", value: "hunter2", inScope: "notes-scope", notes: "issued by ops")

                let model = WorkshopModel(
                    environment: [
                        "SHARIBAKO_VAULT": vault.path,
                        "SHARIBAKO_AGE_KEY": keyURL.path,
                    ],
                    home: URL(fileURLWithPath: "/Users/nobody")
                )
                model.selectedScopeID = "notes-scope"
                model.selectedSecretKey = "TOKEN"
                model.reveal(key: "TOKEN", inScope: "notes-scope")

                #expect(model.revealedValue == "hunter2")
                #expect(model.revealedNotes == "issued by ops")

                // Selection change clears notes through the same cascade as the value.
                model.selectedSecretKey = nil
                #expect(model.revealedValue == nil)
                #expect(model.revealedNotes == nil)
            }
        }
    }

    @Test("reveal of a secret without notes leaves revealedNotes nil")
    func revealWithoutNotesLeavesNotesNil() throws {
        try withEphemeralAgeKey { keyURL in
            try WorkshopTestSupport.withTempVault { vault in
                try WorkshopTestSupport.writeScope("plain-scope", type: .other, in: vault)
                let core = try VaultCore(vaultURL: vault, ageKeyURL: keyURL)
                try core.addSecret("TOKEN", value: "no-notes-here", inScope: "plain-scope")

                let model = WorkshopModel(
                    environment: [
                        "SHARIBAKO_VAULT": vault.path,
                        "SHARIBAKO_AGE_KEY": keyURL.path,
                    ],
                    home: URL(fileURLWithPath: "/Users/nobody")
                )
                model.selectedScopeID = "plain-scope"
                model.selectedSecretKey = "TOKEN"
                model.reveal(key: "TOKEN", inScope: "plain-scope")

                #expect(model.revealedValue == "no-notes-here")
                #expect(model.revealedNotes == nil)
            }
        }
    }
}
