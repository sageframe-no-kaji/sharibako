import ArgumentParser
import Foundation
import Testing

@testable import SharibakoCLI
@testable import SharibakoCore

/// Tests for `sharibako run`.
///
/// `_run` resolves the scope, decrypts, composes the child environment, and returns
/// `RunOutcome.ready` **without** exec-ing — so these drive it in-process and read the
/// composed environment back. The actual `execve` (ho-04.13) lives in `ExecReplace`,
/// which replaces the process image and can only be exercised by the dogfood gate; the
/// exec-side behaviors (exit-code propagation, signal-death mapping, chdir failure) move
/// there with it. Serialized because `scopeWinsOverParentEnv` mutates the process's own
/// environment.
@Suite("sharibako run", .serialized)
struct RunCommandTests {
    /// Parses an argv into a `RunCommand` via the root command's dispatch.
    private func parseRun(_ args: [String]) throws -> RunCommand {
        let root = try SharibakoCommand.parseAsRoot(args)
        return try #require(root as? RunCommand)
    }

    /// Makes a throwaway project directory for the child's cwd; removed after `body`.
    private func withProjectDir(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sb-run-proj-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    /// Unwraps a `.ready` outcome's composed environment, failing the test otherwise.
    private func readyEnvironment(_ outcome: RunOutcome) throws -> [String: String] {
        guard case .ready(let environment, _, _) = outcome else {
            Issue.record("expected .ready, got \(outcome)")
            throw CLIError.runCommandEmpty
        }
        return environment
    }

    @Test("Composes scope secrets into the child environment")
    func composesEnvironment() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vault, key in
            try CLITestSupport.writeScope("proj", in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: key)
            try core.addSecret("FOO", value: "bar-123", inScope: "proj")

            try withProjectDir { proj in
                let cmd = try parseRun([
                    "run", "--vault", vault.path, "--age-key", key.path, "--scope", "proj",
                    "--", "sh", "-c", "true",
                ])
                let env = try readyEnvironment(cmd._run(cwd: proj))
                #expect(env["FOO"] == "bar-123")
            }
        }
    }

    @Test("Scope value wins over an inherited parent-environment value")
    func scopeWinsOverParentEnv() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vault, key in
            try CLITestSupport.writeScope("proj", in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: key)
            try core.addSecret("SHARIBAKO_RUN_TEST_KEY", value: "scope-val", inScope: "proj")

            setenv("SHARIBAKO_RUN_TEST_KEY", "parent-val", 1)
            defer { unsetenv("SHARIBAKO_RUN_TEST_KEY") }

            try withProjectDir { proj in
                let cmd = try parseRun([
                    "run", "--vault", vault.path, "--age-key", key.path, "--scope", "proj",
                    "--", "sh", "-c", "true",
                ])
                let env = try readyEnvironment(cmd._run(cwd: proj))
                #expect(env["SHARIBAKO_RUN_TEST_KEY"] == "scope-val")
            }
        }
    }

    @Test("Passes the command through to the outcome, keeping the -- separator for env")
    func passesCommandThrough() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vault, key in
            try CLITestSupport.writeScope("proj", in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: key)
            try core.addSecret("FOO", value: "x", inScope: "proj")

            try withProjectDir { proj in
                let cmd = try parseRun([
                    "run", "--vault", vault.path, "--age-key", key.path, "--scope", "proj",
                    "--", "node", "app.js",
                ])
                guard case .ready(_, let command, let cwd) = try cmd._run(cwd: proj) else {
                    Issue.record("expected .ready")
                    return
                }
                // `.captureForPassthrough` keeps the leading `--`; ExecReplace hands it to
                // /usr/bin/env, which consumes it — parity with the old Process path.
                #expect(command == ["--", "node", "app.js"])
                #expect(cwd == proj)
            }
        }
    }

    @Test("--dry-run lists sorted names, decrypts nothing, needs no age key")
    func dryRunNeedsNoKey() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vault, key in
            try CLITestSupport.writeScope("proj", in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: key)
            try core.addSecret("FOO", value: "x", inScope: "proj")
            try core.addSecret("BAZ", value: "y", inScope: "proj")

            try withProjectDir { proj in
                // No --age-key supplied: if dry-run tried to decrypt it would need one.
                let cmd = try parseRun(["run", "--vault", vault.path, "--scope", "proj", "--dry-run"])
                let outcome = try cmd._run(cwd: proj)
                #expect(outcome == .dryRun(names: ["BAZ", "FOO"]))
            }
        }
    }

    @Test("Empty command without --dry-run is a usage error")
    func emptyCommandErrors() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vault, key in
            try CLITestSupport.writeScope("proj", in: vault)
            try withProjectDir { proj in
                let cmd = try parseRun([
                    "run", "--vault", vault.path, "--age-key", key.path, "--scope", "proj",
                ])
                #expect(throws: CLIError.runCommandEmpty) {
                    _ = try cmd._run(cwd: proj)
                }
            }
        }
    }

    @Test("An empty scope still composes the parent environment and a zero-count line")
    func emptyScopeStillComposes() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vault, key in
            try CLITestSupport.writeScope("empty", in: vault)
            try withProjectDir { proj in
                let cmd = try parseRun([
                    "run", "--vault", vault.path, "--age-key", key.path, "--scope", "empty",
                    "--", "sh", "-c", "true",
                ])
                let feedback = CLITestSupport.FeedbackCollector()
                let outcome = try cmd._run(cwd: proj, feedback: feedback.sink())
                guard case .ready = outcome else {
                    Issue.record("expected .ready")
                    return
                }
                // The zero-count startup line replaces the former empty-scope note.
                #expect(feedback.lines.contains("sharibako: scope 'empty' — no secrets to inject → sh -c true"))
            }
        }
    }

    @Test("Emits the startup line to the feedback sink, never to stdout, never a value")
    func emitsStartupLine() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vault, key in
            try CLITestSupport.writeScope("proj", in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: key)
            try core.addSecret("FOO", value: "bar", inScope: "proj")

            try withProjectDir { proj in
                let cmd = try parseRun([
                    "run", "--vault", vault.path, "--age-key", key.path, "--scope", "proj",
                    "--", "sh", "-c", "true",
                ])
                let feedback = CLITestSupport.FeedbackCollector()
                _ = try cmd._run(cwd: proj, feedback: feedback.sink())
                // Feedback flows only through the injected sink — the sole emission path,
                // so stdout is untouched by construction. The secret's value never appears.
                #expect(feedback.lines == ["sharibako: scope 'proj' — 1 secret → sh -c true"])
                #expect(!feedback.lines.contains { $0.contains("bar") })
            }
        }
    }

    @Test("Decrypt failure with the wrong key rethrows after releasing the handle")
    func decryptFailureRethrows() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vault, key in
            try CLITestSupport.writeScope("proj", in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: key)
            try core.addSecret("FOO", value: "x", inScope: "proj")

            // A second, unrelated key: decryption of FOO must fail.
            let wrongKeyDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("sb-run-wrongkey-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: wrongKeyDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: wrongKeyDir) }
            let wrongKey = wrongKeyDir.appendingPathComponent("age-key.txt")
            let ageKeygen = try Shell.findExecutable("age-keygen")
            #expect(try Shell.run(ageKeygen, ["-o", wrongKey.path]).exitCode == 0)

            try withProjectDir { proj in
                let cmd = try parseRun([
                    "run", "--vault", vault.path, "--age-key", wrongKey.path, "--scope", "proj",
                    "--", "sh", "-c", "true",
                ])
                #expect(throws: (any Error).self) {
                    _ = try cmd._run(cwd: proj)
                }
            }
        }
    }

    @Test("run --dry-run via run(): returns without exiting")
    func dryRunRunShim() async throws {
        try await CLITestSupport.withEphemeralVaultAndFileKeyAsync { vault, key in
            try CLITestSupport.writeScope("proj", in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: key)
            try core.addSecret("FOO", value: "x", inScope: "proj")

            // Explicit --scope keeps the marker walk away from the test process's
            // real cwd; --dry-run returns from run() before any exec.
            try await CLITestSupport.runCommand([
                "run", "--vault", vault.path, "--scope", "proj", "--dry-run",
            ])
        }
    }

    @Test("Resolves the scope from a cwd marker when --scope is omitted")
    func resolvesScopeFromMarker() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vault, key in
            try CLITestSupport.writeScope("proj", in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: key)
            try core.addSecret("FOO", value: "from-marker", inScope: "proj")

            try withProjectDir { proj in
                try "scope: proj\n".write(
                    to: proj.appendingPathComponent(".sharibako"), atomically: true, encoding: .utf8
                )
                let cmd = try parseRun([
                    "run", "--vault", vault.path, "--age-key", key.path,
                    "--", "sh", "-c", "true",
                ])
                let env = try readyEnvironment(cmd._run(cwd: proj))
                #expect(env["FOO"] == "from-marker")
            }
        }
    }
}
