import ArgumentParser
import Foundation
import Testing

@testable import SharibakoCLI
@testable import SharibakoCore

/// Tests for `sharibako run`.
///
/// Serialized because these exercise process-global state — environment variables
/// (scope-wins) and spawned child processes. `_run(forwardSignals: false)` keeps the
/// real signal-handler installation out of the test process; the live forwarding is
/// coverage-excluded and dogfood-validated. Every test drives `_run` directly rather
/// than `run()`, since `run()` calls `Foundation.exit` to propagate the child's status.
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

    @Test("Injects scope secrets into the child's environment")
    func injectsEnvironment() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vault, key in
            try CLITestSupport.writeScope("proj", in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: key)
            try core.addSecret("FOO", value: "bar-123", inScope: "proj")

            try withProjectDir { proj in
                let cmd = try parseRun([
                    "run", "--vault", vault.path, "--age-key", key.path, "--scope", "proj",
                    "--", "sh", "-c", "printf %s \"$FOO\" > out.txt",
                ])
                let outcome = try cmd._run(cwd: proj, forwardSignals: false)
                #expect(outcome == .ran(exitCode: 0))
                let out = try String(contentsOf: proj.appendingPathComponent("out.txt"), encoding: .utf8)
                #expect(out == "bar-123")
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
                    "--", "sh", "-c", "printf %s \"$SHARIBAKO_RUN_TEST_KEY\" > out.txt",
                ])
                _ = try cmd._run(cwd: proj, forwardSignals: false)
                let out = try String(contentsOf: proj.appendingPathComponent("out.txt"), encoding: .utf8)
                #expect(out == "scope-val")
            }
        }
    }

    @Test("Propagates the child's exit code")
    func propagatesExitCode() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vault, key in
            try CLITestSupport.writeScope("proj", in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: key)
            try core.addSecret("FOO", value: "x", inScope: "proj")

            try withProjectDir { proj in
                let cmd = try parseRun([
                    "run", "--vault", vault.path, "--age-key", key.path, "--scope", "proj",
                    "--", "sh", "-c", "exit 7",
                ])
                #expect(try cmd._run(cwd: proj, forwardSignals: false) == .ran(exitCode: 7))
            }
        }
    }

    @Test("Maps signal death to 128 + signum")
    func mapsSignalDeath() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vault, key in
            try CLITestSupport.writeScope("proj", in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: key)
            try core.addSecret("FOO", value: "x", inScope: "proj")

            try withProjectDir { proj in
                let cmd = try parseRun([
                    "run", "--vault", vault.path, "--age-key", key.path, "--scope", "proj",
                    "--", "sh", "-c", "kill -TERM $$",
                ])
                // SIGTERM is 15 → 128 + 15 = 143.
                #expect(try cmd._run(cwd: proj, forwardSignals: false) == .ran(exitCode: 143))
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
                let outcome = try cmd._run(cwd: proj, forwardSignals: false)
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
                    _ = try cmd._run(cwd: proj, forwardSignals: false)
                }
            }
        }
    }

    @Test("Runs the child with the parent environment when the scope is empty")
    func emptyScopeStillRuns() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vault, key in
            try CLITestSupport.writeScope("empty", in: vault)
            try withProjectDir { proj in
                let cmd = try parseRun([
                    "run", "--vault", vault.path, "--age-key", key.path, "--scope", "empty",
                    "--", "sh", "-c", "exit 0",
                ])
                #expect(try cmd._run(cwd: proj, forwardSignals: false) == .ran(exitCode: 0))
            }
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
                    "--", "sh", "-c", "printf %s \"$FOO\" > out.txt",
                ])
                let outcome = try cmd._run(cwd: proj, forwardSignals: false)
                #expect(outcome == .ran(exitCode: 0))
                let out = try String(contentsOf: proj.appendingPathComponent("out.txt"), encoding: .utf8)
                #expect(out == "from-marker")
            }
        }
    }
}
