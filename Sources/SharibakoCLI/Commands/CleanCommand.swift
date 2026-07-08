import ArgumentParser
import Foundation
import SharibakoCore

/// Removes owned lines from the target `.env` file.
///
/// Asks for confirmation unless `--yes` is supplied. Deletes the file entirely when
/// only blanks and comments would remain. No age key required — uses `inspect`
/// which reads filenames only.
struct CleanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean",
        abstract: "Remove owned secrets from the target .env file.",
        discussion: """
            Removes the sharibako-owned lines from a scope's materialized .env, \
            leaving every non-owned line (comments, blanks, config like \
            DEBUG=true) intact. If the file would be left empty or contain only \
            whitespace and comments, it is deleted; otherwise your remaining \
            content stays. 'clean' is the hygiene counterpart to 'materialize': \
            run it when the plaintext values written to disk should no longer \
            persist - after a work session, or before committing if a .env \
            accidentally got staged.

            No age key is required: 'clean' reads only filenames from the vault to \
            know which keys it owns; it never decrypts. The scope is resolved from \
            the argument, or - when omitted - from the nearest .sharibako marker \
            walking up from the current directory (the same discovery git uses for \
            .git). It asks for confirmation first unless --yes is given; when \
            stdin is not a terminal there is nobody to answer, so --yes is \
            required and its absence is a hard error rather than a silent skip.

            EXAMPLES

            Clean the scope for the current project directory, with a prompt:
              sharibako clean

            Clean a named scope non-interactively (in a script):
              sharibako clean paperless-on-jodo --yes

            EXIT CODES

            Exits 130 when a human declines the confirmation, 2 when confirmation \
            is required but stdin is not a terminal and --yes was not passed.
            """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Scope to clean (resolved from the cwd marker when omitted).")
    var scope: String?

    @Flag(name: .long, help: "Skip the confirmation prompt (required when stdin is not a terminal).")
    var yes: Bool = false

    func run() async throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        do { try _run(cwd: cwd) { readLine() } } catch {
            ErrorReporter.report(error, json: global.json)
        }
    }

    // MARK: - Internal for testing

    // _run: leading-underscore testable-entry-point convention (.swift-format NoLeadingUnderscores: false).
    // swiftlint:disable:next identifier_name
    func _run(
        cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        isInteractive: Bool = TerminalDetector.isInteractiveInput,
        lineReader: () -> String? = { readLine() }
    ) throws {
        let vaultURL = try VaultLocator.resolve(globalFlag: global.vaultURL)
        let vault = try VaultCore(vaultURL: vaultURL)
        let materializer = Materializer(vaultCore: vault, vaultURL: vaultURL)

        let (scopeID, discovered) = try ScopeResolver.resolve(
            explicit: scope, startingFrom: cwd, materializer: materializer
        )
        let marker = try discovered ?? materializer.resolveMarker(forScope: scopeID, scanRoots: [cwd])

        if !yes {
            // Without a terminal there is nobody to answer the prompt — fail
            // loudly instead of declining by default and exiting 0 as a
            // hygiene false positive (ho-04.11).
            guard isInteractive else {
                throw CLIError.promptRequiresTTY(command: "clean", flag: "--yes")
            }
            guard confirmClean(marker: marker, vault: vault, lineReader: lineReader) else {
                // A human declined — that's an abort (exit 130), not success.
                throw CLIError.aborted
            }
        }

        let result = try materializer.clean(marker: marker)
        renderResult(result)
    }

    private func confirmClean(marker: ScopeMarker, vault: VaultCore, lineReader: () -> String?) -> Bool {
        let count = (try? vault.inspect(marker.scope).count) ?? 0
        // Prompt goes to stderr like every other prompt in the CLI — stdout
        // may be piped, and a prompt there corrupts the stream.
        fputs("About to remove \(count) owned key(s) from \(marker.targetURL.path). Continue? [y/N] ", stderr)
        let answer = (lineReader() ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return answer == "y" || answer == "yes"
    }

    private func renderResult(_ result: CleanResult) {
        switch result {
        case .cleaned(let path, let keys, let stillExists):
            if stillExists {
                print("Removed \(keys.count) key(s) from \(path.path)")
            } else {
                print("Removed \(keys.count) key(s); \(path.path) was empty and has been deleted")
            }
        case .fileMissing(let path):
            print("Nothing to clean at \(path.path)")
        }
    }
}
