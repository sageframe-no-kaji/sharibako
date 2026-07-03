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

    // MARK: - Stdin

    @Test("Stdin bytes reach the child, followed by EOF")
    func stdinReachesChild() throws {
        let payload = Data("hello from stdin".utf8)
        let result = try Shell.run(shellBinary, ["-c", "cat"], stdin: payload)
        #expect(result.exitCode == 0)
        #expect(result.stdout == "hello from stdin")
    }

    @Test(
        "Stdin larger than the pipe buffer does not deadlock against large output",
        .timeLimit(.minutes(1))
    )
    func largeStdinAndStdoutDoNotDeadlock() throws {
        // The child echoes everything back, so both the stdin write side and
        // the stdout drain side exceed the ~64 KiB kernel buffer at once. A
        // synchronous stdin write would deadlock here.
        let payload = Data(repeating: UInt8(ascii: "x"), count: 200_000)
        let result = try Shell.run(shellBinary, ["-c", "cat"], stdin: payload)
        #expect(result.exitCode == 0)
        #expect(result.stdout.count == 200_000)
    }

    @Test(
        "A child that never reads stdin exits cleanly instead of killing the parent",
        .timeLimit(.minutes(1))
    )
    func childIgnoringStdinDoesNotRaiseSigpipe() throws {
        // Large payload guarantees the background write outlives the child,
        // forcing the EPIPE path that would be SIGPIPE without F_SETNOSIGPIPE.
        let payload = Data(repeating: UInt8(ascii: "y"), count: 200_000)
        let result = try Shell.run(shellBinary, ["-c", "exit 7"], stdin: payload)
        #expect(result.exitCode == 7)
    }

    @Test("Nil stdin leaves the child's standard input inherited")
    func nilStdinInherited() throws {
        // Behavior guard for existing call sites: no stdin pipe is created,
        // so the child does not see an unconditional immediate EOF from us.
        let result = try Shell.run(shellBinary, ["-c", "printf ok"])
        #expect(result.stdout == "ok")
    }

    // MARK: - Exit codes

    @Test("Non-zero exit codes are captured, not thrown")
    func nonZeroExitCaptured() throws {
        let result = try Shell.run(shellBinary, ["-c", "exit 3"])
        #expect(result.exitCode == 3)
    }
}
