import ArgumentParser
import Foundation
import SharibakoCore

/// Writes owned secrets from the vault into the target `.env` file.
///
/// Scope may be omitted when standing inside a project directory with a `.sharibako`
/// marker (same discovery as git's `.git/`). Touch ID fires once for all owned keys.
struct MaterializeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "materialize",
        abstract: "Write vault secrets into the target .env file.",
        discussion: """
            Merges a scope's owned secrets into the .env at the marker's target \
            path, decrypting each owned value and writing its KEY=value line while \
            preserving every non-owned line - comments, blanks, and config like \
            DEBUG=true - byte for byte. Touch ID fires once for all owned keys. \
            The scope is taken from the argument, or resolved from the nearest \
            .sharibako marker walking up from the current directory when omitted.

            SECURITY - plaintext at rest

            'materialize' is the one verb that puts decrypted values on disk. Any \
            process that can read the file can read the secrets - including AI \
            coding agents, IDE indexers, backups, and cloud-sync clients. Use it \
            ONLY for consumers that cannot be wrapped: docker-compose services, \
            systemd units, cron jobs - anything that starts on boot or a schedule \
            with no interactive process to attach to. For anything you launch \
            interactively, use 'sharibako run', which keeps values off disk \
            entirely. The file is written mode 0600 (owner-only) on every \
            materialize; clean it up afterward with 'sharibako clean'.

            If the file already contains owned lines whose values differ from the \
            vault, 'materialize' stops and reports the drift rather than \
            silently clobbering hand-edits; rerun with --force to overwrite, or \
            use 'update' to pull those edits into the vault instead.

            EXAMPLES

            Materialize the current project's .env:
              sharibako materialize

            Materialize a homelab service scope, overwriting drift:
              sharibako materialize paperless-on-jodo --force

            EXIT CODES

            Exits 2 when drift is detected without --force, 2 for an unknown scope \
            or missing marker, 4/6 on decrypt/Keychain failures.
            """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Scope to materialize (resolved from the cwd marker when omitted).")
    var scope: String?

    @Flag(name: .long, help: "Overwrite differing owned lines (materialize otherwise stops at the diff, exit 2).")
    var force: Bool = false

    func run() async throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        do { try _run(cwd: cwd) } catch { ErrorReporter.report(error, json: global.json) }
    }

    // MARK: - Internal for testing

    // _run: leading-underscore testable-entry-point convention (.swift-format NoLeadingUnderscores: false).
    // swiftlint:disable:next identifier_name
    func _run(cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) throws {
        let vaultURL = try VaultLocator.resolve(globalFlag: global.vaultURL)
        let provider = VaultLocator.resolveProvider(globalFlag: global.ageKeyURL)
        let handle = try provider.loadIdentity(reason: "Decrypt secrets for materialize")
        defer { handle.release() }
        let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: handle.url)
        let materializer = Materializer(vaultCore: vault, vaultURL: vaultURL)

        let marker = try resolvedMarker(explicit: scope, cwd: cwd, materializer: materializer)
        let result = try materializer.materialize(marker: marker, overwriteDrift: force)
        try renderResult(result)
    }

    private func resolvedMarker(explicit: String?, cwd: URL, materializer: Materializer) throws -> ScopeMarker {
        let (scopeID, discovered) = try ScopeResolver.resolve(
            explicit: explicit, startingFrom: cwd, materializer: materializer
        )
        return try discovered ?? materializer.resolveMarker(forScope: scopeID, scanRoots: [cwd])
    }

    private func renderResult(_ result: MaterializeResult) throws {
        switch result {
        case .wrote(let path, let keys):
            print("Wrote \(path.path) (\(keys.count) owned key(s): \(keys.joined(separator: ", ")))")
        case .unchanged(let path):
            print("\(path.path) already up to date")
        case .diffPending(let diff):
            renderDiff(diff)
            throw CLIError.materializeDiffPending
        }
    }

    private func renderDiff(_ diff: MaterializeDiff) {
        fputs("Drift detected in \(diff.path.path):\n", stderr)
        for key in diff.ownedKeysDiffering {
            fputs("  ~ \(key): file value differs from vault\n", stderr)
        }
        for key in diff.ownedKeysMissingFromFile {
            fputs("  + \(key): missing from file\n", stderr)
        }
        fputs("Rerun with --force to overwrite.\n", stderr)
    }
}
