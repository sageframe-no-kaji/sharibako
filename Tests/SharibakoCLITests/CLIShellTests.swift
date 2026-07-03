import Foundation
import Testing

@testable import SharibakoCLI
@testable import SharibakoCore

@Suite("CLIShell")
struct CLIShellTests {
    @Test("findExecutable locates a binary on the standard search paths")
    func findExecutableLocatesGit() throws {
        let git = try CLIShell.findExecutable("git")
        #expect(FileManager.default.fileExists(atPath: git.path))
        #expect(git.lastPathComponent == "git")
    }

    @Test("findExecutable throws shellNotFound for a binary that does not exist")
    func findExecutableMissingThrows() {
        let bogus = "sharibako-no-such-binary-\(UUID().uuidString)"
        let error = #expect(throws: VaultError.self) {
            _ = try CLIShell.findExecutable(bogus)
        }
        guard case .shellNotFound(let name) = error else {
            Issue.record("expected shellNotFound, got \(String(describing: error))")
            return
        }
        #expect(name == bogus)
    }

    @Test("run captures stdout, stderr, and a non-zero exit code")
    func runCapturesStreamsAndExitCode() throws {
        let sh = URL(fileURLWithPath: "/bin/sh")
        let result = try CLIShell.run(sh, ["-c", "printf out; printf err 1>&2; exit 3"])
        #expect(result.exitCode == 3)
        #expect(result.stdout == "out")
        #expect(result.stderr == "err")
    }

    @Test("run reports exit code 0 for a successful invocation")
    func runSuccessExitCode() throws {
        let sh = URL(fileURLWithPath: "/bin/sh")
        let result = try CLIShell.run(sh, ["-c", "exit 0"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.isEmpty)
    }
}
