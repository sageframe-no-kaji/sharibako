import ArgumentParser
import Foundation
import SharibakoCore

/// Result of a `run` invocation, returned by ``RunCommand/_run(cwd:forwardSignals:)`` so
/// tests can assert the outcome without the process actually calling `Foundation.exit`.
enum RunOutcome: Equatable {
    /// `--dry-run`: the sorted secret names that were printed (no values, no decryption).
    case dryRun(names: [String])
    /// A child ran to completion; carries the shell-convention exit code the wrapper
    /// should exit with (`128 + signum` when the child died from a signal).
    case ran(exitCode: Int32)
}

/// Runs a command with a scope's secrets in its environment — nothing written to disk.
///
/// The peer of `materialize` (kamae-2.1): where `materialize` writes a plaintext `.env`,
/// `run` decrypts into memory and hands the values to a child process, closing the Class 4
/// workspace-file-reader exposure for consumers that can be wrapped. Touch ID fires once
/// per invocation, exactly as `materialize` and `get` do.
struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a command with a scope's secrets in its environment (nothing written to disk)."
    )

    @OptionGroup var global: GlobalOptions

    @Option(name: .long, help: "Scope to run under (resolved from the cwd marker when omitted).")
    var scope: String?

    @Flag(name: .long, help: "Print the names of secrets that would be injected, then exit. No values, no Touch ID.")
    var dryRun: Bool = false

    @Argument(parsing: .captureForPassthrough, help: "The command and its arguments (after `--`).")
    var command: [String] = []

    /// Production entry point.
    ///
    /// A thin exit-mapping shim over ``_run(cwd:forwardSignals:)`` — coverage-excluded
    /// because it calls `Foundation.exit`, which cannot run in-process without terminating
    /// the test runner. The decision logic it wraps is tested via `_run`.
    func run() async throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        do {
            switch try _run(cwd: cwd) {
            case .dryRun:
                return  // names already printed to stdout
            case .ran(let code):
                Foundation.exit(code)
            }
        } catch {
            ErrorReporter.report(error, json: global.json)
        }
    }

    // MARK: - Internal for testing

    // _run: leading-underscore testable-entry-point convention (.swift-format NoLeadingUnderscores: false).
    /// Resolves the scope, decrypts its secrets, and spawns the child — returning the
    /// outcome instead of exiting, so tests can drive it in-process.
    ///
    /// - Parameters:
    ///   - cwd: Directory the child runs in and the marker walk-up starts from.
    ///   - forwardSignals: When `false`, skips installing the process-wide signal
    ///     handlers so parallel tests don't race on global signal state. Production
    ///     (`run()`) leaves this `true`.
    ///   - feedback: Stderr feedback sink. `nil` builds one from `--json`/`--verbose`
    ///     and whether stderr is a TTY; tests pass a capturing sink with a forced gate.
    /// - Returns: ``RunOutcome/dryRun(names:)`` for `--dry-run`, else ``RunOutcome/ran(exitCode:)``
    ///   carrying the child's shell-convention exit code.
    /// - Throws: `VaultError` for vault/scope/decrypt failures; `CLIError.runCommandEmpty`
    ///   when no command was given; `CLIError.runSpawnFailed` when the child can't be spawned.
    func _run(  // swiftlint:disable:this identifier_name
        cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        forwardSignals: Bool = true,
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
        // and release the key handle BEFORE the child spawns — the Keychain
        // provider's plaintext temp key file must not sit in $TMPDIR for the
        // child's whole lifetime (hours, for a dev server).
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

        return try spawnAndWait(
            command: command,
            environment: environment,
            cwd: cwd,
            forwardSignals: forwardSignals,
            feedback: sink
        )
    }

    /// Spawns the child through `/usr/bin/env` (so bare command names resolve on PATH),
    /// inherits stdio, forwards signals, and maps termination to a shell-convention code.
    private func spawnAndWait(
        command: [String],
        environment: [String: String],
        cwd: URL,
        forwardSignals: Bool,
        feedback: RunFeedback
    ) throws -> RunOutcome {
        let process = Process()
        // /usr/bin/env resolves bare command names (npm, python) via PATH and execs with
        // the composed environment; standard handles left at defaults inherit the wrapper's.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.environment = environment
        process.currentDirectoryURL = cwd

        do {
            try process.run()
        } catch {
            // Reached only when /usr/bin/env itself can't be launched — a missing command
            // surfaces as the child exiting 127, not as a throw. Defensive; not unit-covered.
            throw CLIError.runSpawnFailed(command: command.first ?? "", underlying: "\(error)")
        }

        // Live signal plumbing (coverage-excluded): tests pass forwardSignals: false so the
        // process-wide handler install doesn't race the parallel runner. Dogfood-validated.
        let forwarder =
            forwardSignals ? SignalForwarder(childPID: process.processIdentifier, feedback: feedback) : nil
        forwarder?.install()
        defer { forwarder?.teardown() }

        process.waitUntilExit()

        switch process.terminationReason {
        case .exit:
            return .ran(exitCode: process.terminationStatus)
        case .uncaughtSignal:
            return .ran(exitCode: 128 + process.terminationStatus)
        @unknown default:
            return .ran(exitCode: process.terminationStatus)
        }
    }
}
