import Foundation
import Testing

@testable import SharibakoCore

/// Tests for the internal `Shell` subprocess helper.
///
/// The large-output cases guard against the classic `Process` deadlock where
/// the parent calls `waitUntilExit()` before draining the pipes: a child that
/// writes more than the kernel pipe buffer (~64 KiB) blocks forever. Each test
/// carries a time limit so a regression fails instead of hanging the run.
@Suite("Shell")
struct ShellTests {
    private let shellBinary = URL(fileURLWithPath: "/bin/sh")

    // MARK: - Pipe draining

    @Test(
        "Output larger than the pipe buffer does not deadlock",
        .timeLimit(.minutes(1))
    )
    func largeStdoutDoesNotDeadlock() throws {
        let result = try Shell.run(
            shellBinary,
            ["-c", "head -c 200000 /dev/zero | tr '\\0' 'x'"]
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout.count == 200_000)
    }

    @Test(
        "Concurrent large stdout and stderr both drain fully",
        .timeLimit(.minutes(1))
    )
    func largeStdoutAndStderrBothDrain() throws {
        let script = """
            head -c 100000 /dev/zero | tr '\\0' 'a'
            head -c 100000 /dev/zero | tr '\\0' 'b' 1>&2
            """
        let result = try Shell.run(shellBinary, ["-c", script])
        #expect(result.exitCode == 0)
        #expect(result.stdout.count == 100_000)
        #expect(result.stderr.count == 100_000)
        #expect(result.stdout.allSatisfy { $0 == "a" })
        #expect(result.stderr.allSatisfy { $0 == "b" })
    }

    // MARK: - Environment overrides

    @Test("Environment overrides reach the child and win over inherited values")
    func environmentOverridesReachChild() throws {
        let result = try Shell.run(
            shellBinary,
            ["-c", "printf '%s' \"$SHARIBAKO_SHELL_TEST\""],
            environmentOverrides: ["SHARIBAKO_SHELL_TEST": "override-value"]
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout == "override-value")
    }

    @Test("Overriding one variable preserves the rest of the inherited environment")
    func environmentOverridesMergeWithInherited() throws {
        let result = try Shell.run(
            shellBinary,
            ["-c", "printf '%s' \"$HOME\""],
            environmentOverrides: ["SHARIBAKO_SHELL_TEST": "present"]
        )
        #expect(result.exitCode == 0)
        #expect(!result.stdout.isEmpty, "inherited HOME should survive an unrelated override")
    }

    @Test("Nil overrides leave the inherited environment untouched")
    func nilOverridesInheritEnvironment() throws {
        let result = try Shell.run(shellBinary, ["-c", "printf '%s' \"$HOME\""])
        #expect(result.exitCode == 0)
        #expect(!result.stdout.isEmpty)
    }

    // MARK: - Exit codes

    @Test("Non-zero exit codes are captured, not thrown")
    func nonZeroExitCaptured() throws {
        let result = try Shell.run(shellBinary, ["-c", "exit 3"])
        #expect(result.exitCode == 3)
    }
}
