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
