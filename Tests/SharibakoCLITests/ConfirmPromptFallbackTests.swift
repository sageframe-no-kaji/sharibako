import Foundation
import Testing

@testable import SharibakoCLI
@testable import SharibakoCore

/// The fallback arms of the two destructive confirmation prompts.
///
/// Both `clean` and `delete` build their prompt from a secret count read
/// through `try?`, and both read the answer through `lineReader() ?? ""`. A
/// marker pointing at a scope the vault no longer has, and a closed stdin
/// (EOF), are the two states that take those fallbacks — and in both cases the
/// right answer is to decline rather than to guess.
@Suite("Confirmation prompt fallbacks")
struct ConfirmPromptFallbackTests {
    /// A project directory holding a `.sharibako` naming `scope` plus a `.env`.
    private func withProject(
        scope: String, _ body: (URL) throws -> Void
    ) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharibako-confirm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "scope: \(scope)\nmaterialize_to: .env\n".write(
            to: dir.appendingPathComponent(".sharibako"), atomically: true, encoding: .utf8)
        try "API_KEY=value\n".write(
            to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try body(dir)
    }

    @Test("clean counts zero keys for a marker whose scope is gone, and EOF declines")
    func cleanWithMissingScopeAndEOF() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            try withProject(scope: "ghost-scope") { projectDir in
                let cmd = try CleanCommand.parse(["--vault", vaultURL.path])

                // The scope is absent, so the count read fails and falls back to
                // zero; stdin is at EOF, so the answer falls back to "" — a
                // decline, not an accidental yes.
                #expect(throws: CLIError.self) {
                    try cmd._run(cwd: projectDir, isInteractive: true) { nil }
                }

                // The file is untouched by a declined clean.
                let env = try String(
                    contentsOf: projectDir.appendingPathComponent(".env"), encoding: .utf8)
                #expect(env == "API_KEY=value\n")
            }
        }
    }

    @Test("delete counts zero keys for a scope that does not exist, and EOF declines")
    func deleteWithMissingScopeAndEOF() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            try CLITestSupport.writeScope("real-scope", in: vaultURL)
            let cmd = try DeleteCommand.parse(["--vault", vaultURL.path, "ghost-scope"])

            #expect(throws: CLIError.self) {
                try cmd._run(isInteractive: true) { nil }
            }

            #expect(try VaultCore(vaultURL: vaultURL).listScopes().map(\.identity) == ["real-scope"])
        }
    }
}
