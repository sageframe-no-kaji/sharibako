import Foundation
import Testing

@testable import SharibakoCore

/// Tests for the `Conduit` type's local git operations.
///
/// Every test runs inside an ephemeral temp-directory vault that is cleaned up
/// on exit. Remote operations (`push`, `pull`) are AT-02 work and are not covered here.
@Suite("Conduit Local")
struct ConduitLocalTests {
    // MARK: - Initializer

    @Test("init succeeds for an existing vault directory")
    func initSucceedsForExistingDirectory() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            let conduit = try Conduit(vaultURL: vault)
            #expect(conduit.vaultURL == vault)
        }
    }

    @Test("init throws vaultNotFound for a nonexistent path")
    func initThrowsForMissingDirectory() {
        let bogus = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: VaultError.self) {
            _ = try Conduit(vaultURL: bogus)
        }
    }

    // MARK: - initializeRepository

    @Test("initializeRepository creates .git when absent")
    func initializeRepositoryCreatesGitDir() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            let conduit = try Conduit(vaultURL: vault)
            let gitDir = vault.appendingPathComponent(".git")
            #expect(!FileManager.default.fileExists(atPath: gitDir.path))
            try conduit.initializeRepository()
            #expect(FileManager.default.fileExists(atPath: gitDir.path))
        }
    }

    @Test("initializeRepository is a no-op when .git already exists")
    func initializeRepositoryIsIdempotent() throws {
        try VaultTestSupport.withEphemeralGitVault { vault in
            let conduit = try Conduit(vaultURL: vault)
            let gitDir = vault.appendingPathComponent(".git")
            let modDate1 =
                try FileManager.default.attributesOfItem(atPath: gitDir.path)[.modificationDate] as? Date
            // Second call must not fail and must not alter the .git directory's mod time.
            try conduit.initializeRepository()
            let modDate2 =
                try FileManager.default.attributesOfItem(atPath: gitDir.path)[.modificationDate] as? Date
            #expect(modDate1 == modDate2)
        }
    }

    // MARK: - setIdentity

    @Test("setIdentity writes user.name and user.email to .git/config")
    func setIdentityWritesConfig() throws {
        try VaultTestSupport.withEphemeralGitVault { vault in
            // withEphemeralGitVault already called setIdentity; read the config to verify.
            let gitConfig = vault.appendingPathComponent(".git/config")
            let contents = try String(contentsOf: gitConfig, encoding: .utf8)
            #expect(contents.contains("name = Sharibako Tests"))
            #expect(contents.contains("email = tests@example.invalid"))
        }
    }

    // MARK: - setRemote / remoteURL

    @Test("remoteURL returns nil when no remote is configured")
    func remoteURLReturnsNilWhenAbsent() throws {
        try VaultTestSupport.withEphemeralGitVault { vault in
            let conduit = try Conduit(vaultURL: vault)
            let url = try conduit.remoteURL()
            #expect(url == nil)
        }
    }

    @Test("setRemote adds origin when there is no remote yet")
    func setRemoteAddsOrigin() throws {
        try VaultTestSupport.withEphemeralGitVault { vault in
            let conduit = try Conduit(vaultURL: vault)
            try conduit.setRemote("https://example.invalid/repo.git")
            let url = try conduit.remoteURL()
            #expect(url == "https://example.invalid/repo.git")
        }
    }

    @Test("setRemote updates origin when one already exists")
    func setRemoteUpdatesExistingOrigin() throws {
        try VaultTestSupport.withEphemeralGitVault { vault in
            let conduit = try Conduit(vaultURL: vault)
            try conduit.setRemote("https://example.invalid/first.git")
            try conduit.setRemote("https://example.invalid/second.git")
            let url = try conduit.remoteURL()
            #expect(url == "https://example.invalid/second.git")
        }
    }

    @Test("remoteURL returns the configured URL when one is set")
    func remoteURLReturnsSavedURL() throws {
        try VaultTestSupport.withEphemeralGitVault { vault in
            let conduit = try Conduit(vaultURL: vault)
            try conduit.setRemote("git@github.com:example/sharibako-vault.git")
            let url = try conduit.remoteURL()
            #expect(url == "git@github.com:example/sharibako-vault.git")
        }
    }

    // MARK: - status

    @Test("status on an initialized empty repo returns clean state")
    func statusEmptyRepo() throws {
        try VaultTestSupport.withEphemeralGitVault { vault in
            let conduit = try Conduit(vaultURL: vault)
            let result = try conduit.status()
            #expect(!result.dirty)
            #expect(result.untrackedFiles.isEmpty)
            #expect(result.modifiedFiles.isEmpty)
            #expect(result.deletedFiles.isEmpty)
            #expect(result.ahead == 0)
            #expect(result.behind == 0)
            #expect(!result.hasRemote)
        }
    }

    @Test("status reports dirty=true and untrackedFiles for a new file")
    func statusWithUntrackedFile() throws {
        try VaultTestSupport.withEphemeralGitVault { vault in
            let newFile = vault.appendingPathComponent("scopes/new-file.txt")
            try "hello".write(to: newFile, atomically: true, encoding: .utf8)
            let conduit = try Conduit(vaultURL: vault)
            let result = try conduit.status()
            #expect(result.dirty)
            #expect(!result.untrackedFiles.isEmpty)
        }
    }

    @Test("status reports dirty=true and modifiedFiles for a modified tracked file")
    func statusWithModifiedTrackedFile() throws {
        try VaultTestSupport.withEphemeralGitVault { vault in
            let conduit = try Conduit(vaultURL: vault)
            // Write a file and commit it.
            let trackedFile = vault.appendingPathComponent("scopes/tracked.txt")
            try "initial".write(to: trackedFile, atomically: true, encoding: .utf8)
            _ = try conduit.commit(message: "add tracked file")
            // Now modify it without staging.
            try "modified".write(to: trackedFile, atomically: true, encoding: .utf8)
            let result = try conduit.status()
            #expect(result.dirty)
            #expect(!result.modifiedFiles.isEmpty)
        }
    }

    @Test("status reports deletedFiles when a tracked file is removed")
    func statusWithDeletedTrackedFile() throws {
        try VaultTestSupport.withEphemeralGitVault { vault in
            let conduit = try Conduit(vaultURL: vault)
            // Commit a tracked file.
            let trackedFile = vault.appendingPathComponent("scopes/to-delete.txt")
            try "value".write(to: trackedFile, atomically: true, encoding: .utf8)
            _ = try conduit.commit(message: "add file to delete")
            // Remove it from the filesystem without staging the deletion — git sees it as
            // a worktree deletion (XY = " D") and reports it in deletedFiles.
            try FileManager.default.removeItem(at: trackedFile)
            let result = try conduit.status()
            #expect(result.dirty)
            #expect(!result.deletedFiles.isEmpty)
            #expect(result.deletedFiles.contains(trackedFile))
        }
    }

    @Test("status reports rename entry as a modified file")
    func statusWithRenamedTrackedFile() throws {
        try VaultTestSupport.withEphemeralGitVault { vault in
            let conduit = try Conduit(vaultURL: vault)
            // Commit a file named old.txt.
            let oldFile = vault.appendingPathComponent("scopes/old.txt")
            try "data".write(to: oldFile, atomically: true, encoding: .utf8)
            _ = try conduit.commit(message: "add old.txt")
            // Use `git mv` to rename — this stages the rename, which porcelain v2 reports
            // as a "2 R..." line (renamed/copied entry).
            let git = try Shell.findExecutable("git")
            _ = try Shell.run(
                git,
                ["mv", "scopes/old.txt", "scopes/new.txt"],
                workingDirectory: vault
            )
            let newFile = vault.appendingPathComponent("scopes/new.txt")
            let result = try conduit.status()
            #expect(result.dirty)
            // The new path must appear in modifiedFiles (renames are mapped there).
            #expect(result.modifiedFiles.contains(newFile))
        }
    }

    @Test("status throws gitInvocationFailed for a non-git directory")
    func statusThrowsForNonGitDirectory() throws {
        // Use a plain temp directory that is NOT a git repo.
        let bareDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: bareDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bareDir) }
        let conduit = try Conduit(vaultURL: bareDir)
        #expect(throws: VaultError.self) {
            _ = try conduit.status()
        }
    }

    // MARK: - setIdentity error path

    @Test("setIdentity throws gitInvocationFailed on a non-git directory")
    func setIdentityThrowsForNonGitDirectory() throws {
        // Use a plain temp directory that is NOT a git repo — `git config --local` requires .git/.
        let bareDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: bareDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bareDir) }
        let conduit = try Conduit(vaultURL: bareDir)
        #expect(throws: VaultError.self) {
            try conduit.setIdentity(name: "Test", email: "test@example.invalid")
        }
    }

    // MARK: - setRemote error path

    @Test("setRemote throws gitInvocationFailed when git remote add fails on a non-git directory")
    func setRemoteThrowsForNonGitDirectory() throws {
        // In a non-git directory the probe (`git remote get-url origin`) exits non-zero, so
        // Conduit falls into the `git remote add` branch — which also exits non-zero without .git.
        let bareDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: bareDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bareDir) }
        let conduit = try Conduit(vaultURL: bareDir)
        #expect(throws: VaultError.self) {
            try conduit.setRemote("https://example.invalid/repo.git")
        }
    }

    // MARK: - commit error path

    @Test("commit throws gitInvocationFailed when git add -A fails on a non-git directory")
    func commitThrowsWhenAddFailsForNonGitDirectory() throws {
        // `git add -A` exits non-zero outside a git repository, hitting the guard on line 146.
        let bareDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: bareDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bareDir) }
        let conduit = try Conduit(vaultURL: bareDir)
        #expect(throws: VaultError.self) {
            _ = try conduit.commit(message: "should fail")
        }
    }

    // MARK: - commit

    @Test("commit on a clean working tree with no changes returns .nothingToCommit")
    func commitNothingToCommit() throws {
        try VaultTestSupport.withEphemeralGitVault { vault in
            let conduit = try Conduit(vaultURL: vault)
            let result = try conduit.commit(message: "empty commit attempt")
            #expect(result == .nothingToCommit)
        }
    }

    @Test("commit with staged changes returns success and a valid SHA")
    func commitWithChangesReturnsSuccess() throws {
        try VaultTestSupport.withEphemeralGitVault { vault in
            let conduit = try Conduit(vaultURL: vault)
            // Write a file so there is something to commit.
            let file = vault.appendingPathComponent("scopes/secret.txt")
            try "value".write(to: file, atomically: true, encoding: .utf8)
            let result = try conduit.commit(message: "add secret")
            guard case .success(let sha) = result else {
                Issue.record("Expected .success(sha:) but got \(result)")
                return
            }
            // SHA should be a 40-hex-character string.
            #expect(sha.count == 40)
            #expect(sha.allSatisfy { $0.isHexDigit })
        }
    }

    @Test("commit excludes encrypt-path staging leftovers but keeps them visible in status")
    func commitExcludesStagingLeftovers() throws {
        try VaultTestSupport.withEphemeralGitVault { vault in
            let conduit = try Conduit(vaultURL: vault)
            // A real change plus a crash leftover from the encrypt path's
            // staging write, both at the root and nested in a scope directory.
            let real = vault.appendingPathComponent("scopes/key.age")
            try FileManager.default.createDirectory(
                at: vault.appendingPathComponent("scopes"),
                withIntermediateDirectories: true
            )
            try "ciphertext".write(to: real, atomically: true, encoding: .utf8)
            let strayRoot = vault.appendingPathComponent("\(VaultLayout.stagingPrefix)abc")
            let strayNested = vault.appendingPathComponent("scopes/\(VaultLayout.stagingPrefix)def")
            try "stray".write(to: strayRoot, atomically: true, encoding: .utf8)
            try "stray".write(to: strayNested, atomically: true, encoding: .utf8)

            guard case .success = try conduit.commit(message: "add key") else {
                Issue.record("Expected .success(sha:)")
                return
            }

            // The committed tree carries the real file and neither stray…
            let git = try Shell.findExecutable("git")
            let tree = try Shell.run(git, ["ls-tree", "-r", "--name-only", "HEAD"], workingDirectory: vault)
            #expect(tree.stdout.contains("scopes/key.age"))
            #expect(!tree.stdout.contains(VaultLayout.stagingPrefix))

            // …and the strays remain visible as untracked files (not ignored).
            let status = try Shell.run(git, ["status", "--porcelain"], workingDirectory: vault)
            #expect(status.stdout.contains("\(VaultLayout.stagingPrefix)abc"))
            #expect(status.stdout.contains("scopes/\(VaultLayout.stagingPrefix)def"))
        }
    }

    @Test("commit SHA matches git rev-parse HEAD")
    func commitSHAMatchesRevParse() throws {
        try VaultTestSupport.withEphemeralGitVault { vault in
            let conduit = try Conduit(vaultURL: vault)
            let file = vault.appendingPathComponent("scopes/key.age")
            try "placeholder".write(to: file, atomically: true, encoding: .utf8)
            guard case .success(let sha) = try conduit.commit(message: "verify sha") else {
                Issue.record("Expected .success(sha:)")
                return
            }
            // Independently run rev-parse and compare.
            let git = try Shell.findExecutable("git")
            let revResult = try Shell.run(git, ["rev-parse", "HEAD"], workingDirectory: vault)
            let headSHA = revResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(sha == headSHA)
        }
    }

    @Test("commit on a repo without a configured identity throws gitInvocationFailed")
    func commitWithoutIdentityThrows() throws {
        // Build a vault manually — do NOT call setIdentity — and override GIT_CONFIG_NOSYSTEM
        // plus HOME to ensure no ambient identity bleeds in.
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try VaultLayout.createVaultLayout(at: tempDir)
        let conduit = try Conduit(vaultURL: tempDir)
        try conduit.initializeRepository()
        // Don't call setIdentity — the local config has no user.name / user.email.
        // Write a file so there is something to commit.
        let file = tempDir.appendingPathComponent("scopes/test.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        // Stage explicitly (git add -A) before trying to commit.
        let git = try Shell.findExecutable("git")
        _ = try Shell.run(git, ["add", "-A"], workingDirectory: tempDir)
        // Now override the environment to prevent git picking up a global identity.
        // We can't easily control Process env via Shell.run (it inherits the parent),
        // so instead we write an empty local config section that blocks inheritance.
        let gitConfigURL = tempDir.appendingPathComponent(".git/config")
        var configContents = try String(contentsOf: gitConfigURL, encoding: .utf8)
        configContents += "\n[user]\n\tname =\n\temail =\n"
        try configContents.write(to: gitConfigURL, atomically: true, encoding: .utf8)
        #expect(throws: VaultError.self) {
            _ = try conduit.commit(message: "should fail")
        }
    }
}
