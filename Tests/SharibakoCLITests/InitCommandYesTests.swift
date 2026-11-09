import Foundation
import Testing

@testable import SharibakoCLI
@testable import SharibakoCore

/// `init --yes` and `init` without a terminal (ho-06.10 Decision 3).
///
/// Under `--yes` the class defaults apply and each line's class is printed.
/// Without a terminal and without `--yes`, `init` refuses and writes nothing.
@Suite("InitCommand — --yes and non-TTY defaults")
struct InitCommandYesTests {
    private static let mixedEnv = """
        OPENAI_API_KEY=sk-proj-abc
        PORT=3000
        DATABASE_URL=postgres://u:p@h/db
        NODE_ENV=development
        CLOUDFLARE_ACCOUNT_ID=0123456789abcdef0123456789abcdef
        """

    private func withProjectDir(env: String, _ body: (URL) throws -> Void) throws {
        let projectDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("init-yes-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectDir) }
        try env.write(to: projectDir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try body(projectDir)
    }

    private func makeCommand(vaultURL: URL, keyURL: URL, yes: Bool) throws -> InitCommand {
        let args = ["--vault", vaultURL.path, "--age-key", keyURL.path] + (yes ? ["--yes"] : [])
        return try InitCommand.parse(args)
    }

    @Test("--yes selects the class-default source whether or not stdin is a terminal")
    func yesSelectsClassDefaults() throws {
        let cmd = try InitCommand.parse(["--yes"])
        #expect(cmd.yes)
        #expect(cmd.makeDecisionSource(isInteractive: true) is ClassDefaultIngestDecisionSource)
        #expect(cmd.makeDecisionSource(isInteractive: false) is ClassDefaultIngestDecisionSource)
    }

    @Test("without --yes: the prompt is used, terminal or not, and carries the TTY answer")
    func noYesUsesPrompt() throws {
        let cmd = try InitCommand.parse([])
        #expect(!cmd.yes)
        let interactive = cmd.makeDecisionSource(isInteractive: true) as? PlainIngestPrompt
        let piped = cmd.makeDecisionSource(isInteractive: false) as? PlainIngestPrompt
        #expect(interactive?.isInteractive() == true)
        #expect(piped?.isInteractive() == false)
    }

    @Test("non-TTY without --yes refuses with notInteractiveTerminal and writes nothing")
    func nonTTYWithoutYesRefuses() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try withProjectDir(env: Self.mixedEnv) { projectDir in
                let cmd = try makeCommand(vaultURL: vaultURL, keyURL: keyURL, yes: false)
                #expect(throws: CLIError.notInteractiveTerminal) {
                    try cmd._run(
                        cwd: projectDir,
                        decisionSource: cmd.makeDecisionSource(isInteractive: false)
                    ) { nil }
                }
                #expect(!FileManager.default.fileExists(atPath: projectDir.appendingPathComponent(".sharibako").path))
                #expect(try VaultCore(vaultURL: vaultURL).listScopes().isEmpty)
            }
        }
    }

    @Test("non-TTY with --yes commits the class defaults")
    func nonTTYWithYesCommits() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try withProjectDir(env: Self.mixedEnv) { projectDir in
                let cmd = try makeCommand(vaultURL: vaultURL, keyURL: keyURL, yes: true)
                // The production source for a non-TTY --yes run; swap only its print sink.
                var source = try #require(
                    cmd.makeDecisionSource(isInteractive: false) as? ClassDefaultIngestDecisionSource
                )
                var printed: [String] = []
                source.print = { printed.append($0) }
                try cmd._run(cwd: projectDir, decisionSource: source, lineReader: cmd.makeLineReader())

                #expect(printed.count == 5)
                let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
                let materializer = Materializer(vaultCore: vault, vaultURL: vaultURL)
                let marker = try materializer.loadMarker(at: projectDir.appendingPathComponent(".sharibako"))
                let owned = Set(try vault.inspect(marker.scope).map(\.key))
                #expect(owned == ["OPENAI_API_KEY", "DATABASE_URL", "CLOUDFLARE_ACCOUNT_ID"])
            }
        }
    }

    @Test("--yes answers no prompt, so every prompt takes its default")
    func yesLineReaderAnswersNothing() throws {
        let reader = try InitCommand.parse(["--yes"]).makeLineReader()
        #expect(reader() == nil)
    }

    @Test("--yes prints every key with its class and commits the defaults")
    func yesPrintsClassesAndCommitsDefaults() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try withProjectDir(env: Self.mixedEnv) { projectDir in
                var printed: [String] = []
                var source = ClassDefaultIngestDecisionSource()
                source.print = { printed.append($0) }
                let cmd = try makeCommand(vaultURL: vaultURL, keyURL: keyURL, yes: true)
                try cmd._run(cwd: projectDir, decisionSource: source, lineReader: cmd.makeLineReader())

                #expect(
                    printed == [
                        "PROTECT  OPENAI_API_KEY  (key ends in KEY)",
                        "LEAVE    PORT  (looks like a number)",
                        "PROTECT  DATABASE_URL  (URL carries a username or password)",
                        "LEAVE    NODE_ENV  (looks like a plain word)",
                        "PROTECT  CLOUDFLARE_ACCOUNT_ID  (not recognised as a plain setting)",
                    ]
                )

                // Scope ID and type took their defaults; secrets are in the vault, settings are not.
                let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
                let materializer = Materializer(vaultCore: vault, vaultURL: vaultURL)
                let marker = try materializer.loadMarker(at: projectDir.appendingPathComponent(".sharibako"))
                #expect(marker.scope == projectDir.lastPathComponent.lowercased())
                let owned = Set(try vault.inspect(marker.scope).map(\.key))
                #expect(owned == ["OPENAI_API_KEY", "DATABASE_URL", "CLOUDFLARE_ACCOUNT_ID"])
                #expect(try vault.getValue("DATABASE_URL", inScope: marker.scope) == "postgres://u:p@h/db")

                // The source .env is untouched.
                let envOnDisk = try String(contentsOf: projectDir.appendingPathComponent(".env"), encoding: .utf8)
                #expect(envOnDisk == Self.mixedEnv)
            }
        }
    }

    @Test("--yes never adds to an existing scope: the suggested ID avoids it")
    func yesNeverJoinsExistingScope() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try withProjectDir(env: Self.mixedEnv) { projectDir in
                let core = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
                let existing = projectDir.lastPathComponent.lowercased()
                try core.createScope(existing, type: .projectDev)
                var source = ClassDefaultIngestDecisionSource()
                source.print = { _ in }
                let cmd = try makeCommand(vaultURL: vaultURL, keyURL: keyURL, yes: true)
                try cmd._run(cwd: projectDir, decisionSource: source, lineReader: cmd.makeLineReader())

                let materializer = Materializer(vaultCore: core, vaultURL: vaultURL)
                let marker = try materializer.loadMarker(at: projectDir.appendingPathComponent(".sharibako"))
                #expect(marker.scope == "\(existing)-dev")
                #expect(try core.inspect(existing).isEmpty)
            }
        }
    }
}
