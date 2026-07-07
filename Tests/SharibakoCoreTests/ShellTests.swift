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

    // MARK: - findExecutable PATH resolution (ho-04.12 D6)

    /// Creates a temp directory holding an executable stub named `name`.
    private func makeBinDir(name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shell-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let binary = dir.appendingPathComponent(name)
        FileManager.default.createFile(
            atPath: binary.path,
            contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755]
        )
        return dir
    }

    @Test("findExecutable locates a binary on PATH")
    func findsBinaryOnPath() throws {
        let dir = try makeBinDir(name: "sharibako-fake-tool")
        defer { try? FileManager.default.removeItem(at: dir) }
        let found = try Shell.findExecutable("sharibako-fake-tool", pathVariable: dir.path)
        #expect(found.path == dir.appendingPathComponent("sharibako-fake-tool").path)
    }

    @Test("PATH is searched before the fixed fallback list")
    func pathBeatsFixedFallback() throws {
        // A fake `age` on PATH must win over the real one in the fixed list.
        let dir = try makeBinDir(name: "age")
        defer { try? FileManager.default.removeItem(at: dir) }
        let found = try Shell.findExecutable("age", pathVariable: dir.path)
        #expect(found.deletingLastPathComponent().path == dir.path)
    }

    @Test("PATH entries are searched in order; the first hit wins")
    func pathSearchedInOrder() throws {
        let first = try makeBinDir(name: "sharibako-order-tool")
        let second = try makeBinDir(name: "sharibako-order-tool")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let combined = "\(first.path):\(second.path)"
        let found = try Shell.findExecutable("sharibako-order-tool", pathVariable: combined)
        #expect(found.deletingLastPathComponent().path == first.path)
    }

    @Test("Falls back to the fixed list when PATH lacks the binary")
    func fallsBackToFixedList() throws {
        // Empty PATH forces the fixed list; `age` is a dev/CI prerequisite there.
        let found = try Shell.findExecutable("age", pathVariable: "")
        #expect(found.lastPathComponent == "age")
        #expect(found.path.hasPrefix("/"))
    }

    @Test("Throws shellNotFound when neither PATH nor the fallback has the binary")
    func throwsWhenAbsentEverywhere() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("shell-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let bogus = "sharibako-no-such-binary-\(UUID().uuidString)"
        let error = #expect(throws: VaultError.self) {
            _ = try Shell.findExecutable(bogus, pathVariable: empty.path)
        }
        guard case .shellNotFound(let name) = error else {
            Issue.record("expected shellNotFound, got \(String(describing: error))")
            return
        }
        #expect(name == bogus)
    }
}
