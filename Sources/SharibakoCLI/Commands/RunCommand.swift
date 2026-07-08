import ArgumentParser
import Foundation
import SharibakoCore

/// Result of ``RunCommand/_run(cwd:feedback:)``, returned so tests can assert the
/// outcome in-process without the wrapper replacing itself via `execve`.
enum RunOutcome: Equatable {
    /// `--dry-run`: the sorted secret names that were printed (no values, no decryption).
    case dryRun(names: [String])
    /// The scope decrypted and the child environment composed; the wrapper is ready to
    /// `exec` into `command`. `run()` hands this to ``ExecReplace`` (which never returns);
    /// tests read the composed `environment` back without exec-ing.
    case ready(environment: [String: String], command: [String], cwd: URL)
}

/// Runs a command with a scope's secrets in its environment — nothing written to disk.
///
/// The peer of `materialize` (kamae-2.1): where `materialize` writes a plaintext `.env`,
/// `run` decrypts into memory and hands the values to a child process, closing the Class 4
/// workspace-file-reader exposure for consumers that can be wrapped. Touch ID fires once
/// per invocation, exactly as `materialize` and `get` do.
///
/// Once the environment is composed and the age key released, `run` **replaces its own
/// process image** with the child via ``ExecReplace`` (ho-04.13). No wrapper parent
/// survives the child, so signals, stdin, and the exit code are all native — there is no
/// signal-forwarding code. `--dry-run` returns before any of this.
struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a command with a scope's secrets in its environment (nothing written to disk).",
        discussion: """
            Decrypts a scope's owned secrets into memory, composes them into the \
            environment (the scope's values overlay the inherited environment; \
            the scope wins on a collision), and runs your command with them set. \
            Nothing is written to disk. This is the peer of 'materialize' and the \
            right verb for anything you launch interactively - npm run dev, python \
            app.py, docker-compose up, cargo run. Put the command after a literal \
            '--' so its own flags are not parsed by sharibako. Touch ID fires \
            once, before the command starts. The scope comes from --scope, or is \
            resolved from the nearest .sharibako marker walking up from the \
            current directory.

            EXEC-REPLACE - no wrapper parent

            Once the environment is composed and the age key released, 'run' \
            REPLACES ITS OWN PROCESS IMAGE with the command (via execve). There is \
            no sharibako parent process for the command's lifetime, so signals, \
            stdin, terminal control, and the exit code are all native: Ctrl-C \
            reaches your command directly, an interactive REPL reads the terminal \
            without stopping, and the command's PID is the one your shell \
            launched. There is no signal-forwarding layer to get in the way.

            EXIT CODES

            Because 'run' becomes the command, its exit status IS the command's: \
            'run' propagates the child's exit code unchanged, and a command that \
            dies on a signal exits 128+signum (e.g. 130 for SIGINT/Ctrl-C, 143 \
            for SIGTERM) - the standard shell convention. A missing command \
            surfaces as 127 from /usr/bin/env. (These are the command's codes, not \
            sharibako's taxonomy in sharibako(1).)

            SECURITY

            For the command's lifetime the secret values live in its process \
            environment in plaintext - inherent to the environment-variable \
            pattern 'run' targets. The security boundary is a Mac at rest: the \
            injected environment is protected only by process isolation while the \
            machine is unlocked. 'run' does not redact secrets a command prints to \
            its own stdout/stderr. Use --dry-run to preview which names would be \
            set without decrypting anything - safe to hand to an AI agent that \
            needs to know what secrets exist but must not see their values.

            EXAMPLES

            Run a dev server with the current project's secrets, nothing on disk:
              sharibako run -- npm run dev

            Run under an explicit scope:
              sharibako run --scope kanyo-dev -- docker-compose up

            Preview the injected names without decrypting (no Touch ID):
              sharibako run --dry-run -- npm run dev
            """
    )

    @OptionGroup var global: GlobalOptions

    @Option(name: .long, help: "Scope to run under (resolved from the cwd marker when omitted).")
    var scope: String?

    @Flag(
        name: .long,
        help: "Print the names of secrets that would be injected, then exit. No values, no decryption, no Touch ID."
    )
    var dryRun: Bool = false

    @Argument(parsing: .captureForPassthrough, help: "The command and its arguments, after a literal `--`.")
    var command: [String] = []

    /// Production entry point.
    ///
    /// A thin shim over ``_run(cwd:feedback:)``: `--dry-run` returns; the run case
    /// `exec`s into the command via ``ExecReplace/exec(command:environment:cwd:)``,
    /// which replaces this process and never returns. Coverage-excluded because that
    /// exec cannot run in-process; the decision logic it wraps is tested via `_run`.
    func run() async throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        do {
            switch try _run(cwd: cwd) {
            case .dryRun:
                return  // names already printed to stdout
            case .ready(let environment, let command, let cwd):
                try ExecReplace.exec(command: command, environment: environment, cwd: cwd)
            }
        } catch {
            ErrorReporter.report(error, json: global.json)
        }
    }

    // MARK: - Internal for testing

    // _run: leading-underscore testable-entry-point convention (.swift-format NoLeadingUnderscores: false).
    /// Resolves the scope, decrypts its secrets, and composes the child environment —
    /// returning the outcome instead of exec-ing, so tests can drive it in-process.
    ///
    /// - Parameters:
    ///   - cwd: Directory the child runs in and the marker walk-up starts from.
    ///   - feedback: Stderr feedback sink. `nil` builds one from `--json`/`--verbose`
    ///     and whether stderr is a TTY; tests pass a capturing sink with a forced gate.
    /// - Returns: ``RunOutcome/dryRun(names:)`` for `--dry-run`, else
    ///   ``RunOutcome/ready(environment:command:cwd:)`` carrying the composed environment.
    /// - Throws: `VaultError` for vault/scope/decrypt failures; `CLIError.runCommandEmpty`
    ///   when no command was given.
    func _run(  // swiftlint:disable:this identifier_name
        cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        feedback: RunFeedback? = nil
    ) throws -> RunOutcome {
        let sink =
            feedback
            ?? RunFeedback.make(
                json: global.json, verbose: global.verbose, isTTY: isatty(STDERR_FILENO) != 0
            )
        let vaultURL = try VaultLocator.resolve(globalFlag: global.vaultURL)

        // Scope resolution mirrors materialize: explicit --scope, else walk up for a marker.
        let inspectVault = try VaultCore(vaultURL: vaultURL)
        let materializer = Materializer(vaultCore: inspectVault, vaultURL: vaultURL)
        let (scopeID, _) = try ScopeResolver.resolve(
            explicit: scope, startingFrom: cwd, materializer: materializer
        )

        // --dry-run: names only. Uses inspect (filenames), so no age key and no Touch ID.
        if dryRun {
            let names = try inspectVault.inspect(scopeID).map(\.key).sorted()
            for name in names { print(name) }
            return .dryRun(names: names)
        }

        guard !command.isEmpty else {
            throw CLIError.runCommandEmpty
        }

        // Unlock the age identity once, decrypt every secret for the scope,
        // and release the key handle BEFORE we exec — the Keychain provider's
        // plaintext temp key file must not sit in $TMPDIR for the child's whole
        // lifetime (hours, for a dev server).
        let provider = VaultLocator.resolveProvider(globalFlag: global.ageKeyURL)
        let handle = try provider.loadIdentity(reason: "Decrypt secrets for run")
        let secrets: [String: String]
        do {
            let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: handle.url)
            secrets = try vault.secrets(inScope: scopeID)
        } catch {
            handle.release()
            throw error
        }
        handle.release()

        // Startup line to stderr (a zero count subsumes the former empty-scope note).
        sink.emit(RunFeedback.startupLine(scope: scopeID, secretCount: secrets.count, command: command))

        // Compose the child environment: parent env overlaid with scope secrets (scope wins).
        var environment = ProcessInfo.processInfo.environment
        environment.merge(secrets) { _, scopeValue in scopeValue }

        return .ready(environment: environment, command: command, cwd: cwd)
    }
}
