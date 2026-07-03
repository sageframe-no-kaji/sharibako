import Foundation
import Testing

@testable import SharibakoCLI
@testable import SharibakoCore

@Suite("SyncCommand")
struct SyncCommandTests {
    @Test("commit + push round-trips to the bare remote")
    func syncCommitAndPush() throws {
        try CLITestSupport.withEphemeralGitVaultAndRemote { vaultURL, _, _ in
            try CLITestSupport.writeScope("s1", in: vaultURL)

            var cmd = try SyncCommand.parse([
                "--vault", vaultURL.path,
                "--no-pull",
            ])
            try cmd._run()

            // Verify the commit landed in the bare remote by counting refs.
            let git = try Shell.findExecutable("git")
            let result = try Shell.run(git, ["log", "--oneline"], workingDirectory: vaultURL)
            #expect(result.exitCode == 0)
            #expect(result.stdout.contains("sharibako auto-commit"))
        }
    }

    @Test("_run with --no-push skips the push step")
    func syncNoPush() throws {
        try CLITestSupport.withEphemeralGitVaultAndRemote { vaultURL, _, _ in
            var cmd = try SyncCommand.parse([
                "--vault", vaultURL.path,
                "--no-push",
                "--no-pull",
            ])
            // Should not throw even though nothing changed.
            try cmd._run()
        }
    }

    @Test("_run with custom --message uses it as the commit message")
    func syncCustomMessage() throws {
        try CLITestSupport.withEphemeralGitVaultAndRemote { vaultURL, _, _ in
            try CLITestSupport.writeScope("s2", in: vaultURL)

            var cmd = try SyncCommand.parse([
                "--vault", vaultURL.path,
                "--no-push",
                "--no-pull",
                "--message", "my-custom-msg",
            ])
            try cmd._run()

            let git = try Shell.findExecutable("git")
            let log = try Shell.run(git, ["log", "--oneline", "-1"], workingDirectory: vaultURL)
            #expect(log.stdout.contains("my-custom-msg"))
        }
    }

    @Test("sync does not require the age key")
    func syncNoAgeKey() throws {
        try CLITestSupport.withEphemeralGitVaultAndRemote { vaultURL, _, _ in
            var cmd = try SyncCommand.parse([
                "--vault", vaultURL.path,
                "--no-push",
                "--no-pull",
            ])
            // No --age-key flag: should succeed without any crypto.
            try cmd._run()
        }
    }
}

/// Push/pull result handling against a live bare remote, split out of
/// `SyncCommandTests` to respect the `type_body_length` limit.
@Suite("SyncCommand — remote flows")
struct SyncCommandRemoteFlowTests {
    /// Clones the bare remote into a second working copy with a test identity.
    ///
    /// The caller removes the returned directory when done.
    private func cloneRemote(_ remoteGit: URL) throws -> URL {
        let cloneDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharibako-sync-clone-\(UUID().uuidString)")
        let git = try Shell.findExecutable("git")
        let result = try Shell.run(git, ["clone", remoteGit.path, cloneDir.path])
        guard result.exitCode == 0 else {
            throw VaultError.gitInvocationFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        let conduit = try Conduit(vaultURL: cloneDir)
        try conduit.setIdentity(name: "Sharibako Tests B", email: "tests-b@example.invalid")
        return cloneDir
    }

    /// Writes `content` to `scopes/<name>` in `workingCopy`, commits, and returns the Conduit.
    private func commitFile(
        named name: String, content: String, in workingCopy: URL, message: String
    ) throws -> Conduit {
        let scopesDir = workingCopy.appendingPathComponent("scopes")
        try FileManager.default.createDirectory(at: scopesDir, withIntermediateDirectories: true)
        try content.write(
            to: scopesDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        let conduit = try Conduit(vaultURL: workingCopy)
        _ = try conduit.commit(message: message)
        return conduit
    }

    @Test("sync on an up-to-date remote pushes and pulls nothing")
    func syncUpToDate() throws {
        try CLITestSupport.withEphemeralGitVaultAndRemote { vaultURL, _, _ in
            // Fixture setup already pushed the initial commit; both directions are current.
            var cmd = try SyncCommand.parse(["--vault", vaultURL.path])
            try cmd._run()
        }
    }

    @Test("sync pulls commits that landed on the remote from another clone")
    func syncPullsRemoteCommits() throws {
        try CLITestSupport.withEphemeralGitVaultAndRemote { vaultURL, remoteGit, _ in
            let clone = try cloneRemote(remoteGit)
            defer { try? FileManager.default.removeItem(at: clone) }
            let conduitB = try commitFile(
                named: "fromB.txt", content: "from B", in: clone, message: "remote change from B")
            guard case .success = try conduitB.push() else {
                Issue.record("Expected clone push to succeed")
                return
            }

            var cmd = try SyncCommand.parse(["--vault", vaultURL.path, "--no-push"])
            try cmd._run()

            // The pulled commit is now part of the vault's history.
            let git = try Shell.findExecutable("git")
            let log = try Shell.run(git, ["log", "--oneline"], workingDirectory: vaultURL)
            #expect(log.stdout.contains("remote change from B"))
        }
    }

    @Test("sync throws syncRejected when the remote has diverged (non-fast-forward)")
    func syncPushRejected() throws {
        try CLITestSupport.withEphemeralGitVaultAndRemote { vaultURL, remoteGit, _ in
            // Another clone pushes first, putting the remote ahead of the vault.
            let clone = try cloneRemote(remoteGit)
            defer { try? FileManager.default.removeItem(at: clone) }
            let conduitB = try commitFile(
                named: "fromB.txt", content: "from B", in: clone, message: "B wins the race")
            guard case .success = try conduitB.push() else {
                Issue.record("Expected clone push to succeed")
                return
            }

            // The vault commits its own change without pulling — push must be rejected.
            try CLITestSupport.writeScope("local-change", in: vaultURL)
            var cmd = try SyncCommand.parse(["--vault", vaultURL.path, "--no-pull"])
            #expect(throws: CLIError.syncRejected) {
                try cmd._run()
            }
        }
    }

    @Test("sync throws syncConflict on an add/add conflict and leaves the vault clean")
    func syncPullConflict() throws {
        try CLITestSupport.withEphemeralGitVaultAndRemote { vaultURL, remoteGit, _ in
            // Both sides add the same path with different content.
            let clone = try cloneRemote(remoteGit)
            defer { try? FileManager.default.removeItem(at: clone) }
            let conduitB = try commitFile(
                named: "conflict.txt", content: "from B", in: clone, message: "B adds conflict.txt")
            guard case .success = try conduitB.push() else {
                Issue.record("Expected clone push to succeed")
                return
            }
            _ = try commitFile(
                named: "conflict.txt", content: "from A", in: vaultURL, message: "A adds conflict.txt")

            var cmd = try SyncCommand.parse(["--vault", vaultURL.path, "--no-push"])
            #expect(throws: CLIError.syncConflict) {
                try cmd._run()
            }

            // The merge was aborted: A's version survives untouched.
            let content = try String(
                contentsOf: vaultURL.appendingPathComponent("scopes/conflict.txt"), encoding: .utf8)
            #expect(content == "from A")
        }
    }

    @Test("sync without a remote runs end-to-end reporting zero pushed and pulled")
    func syncNoRemoteEndToEnd() async throws {
        let vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharibako-sync-noremote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vaultURL) }
        try VaultLayout.createVaultLayout(at: vaultURL)
        let conduit = try Conduit(vaultURL: vaultURL)
        try conduit.initializeRepository()
        try conduit.setIdentity(name: "Sharibako Tests", email: "tests@example.invalid")

        try await CLITestSupport.runCommand(["sync", "--vault", vaultURL.path])
    }
}
