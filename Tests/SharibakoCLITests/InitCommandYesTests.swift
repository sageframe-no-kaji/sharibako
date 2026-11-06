import Foundation
import Testing

@testable import SharibakoCLI
@testable import SharibakoCore

/// `init --yes` and `init` without a terminal: the class defaults apply and
/// each line's class is printed (ho-06.10 Decision 3).
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

    @Test("without --yes: a terminal gets the prompt, no terminal gets the class defaults")
    func noYesFollowsTerminal() throws {
        let cmd = try InitCommand.parse([])
        #expect(!cmd.yes)
        #expect(cmd.makeDecisionSource(isInteractive: true) is PlainIngestPrompt)
        #expect(cmd.makeDecisionSource(isInteractive: false) is ClassDefaultIngestDecisionSource)
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
