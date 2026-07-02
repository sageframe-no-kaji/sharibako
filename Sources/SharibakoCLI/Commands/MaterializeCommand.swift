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
        abstract: "Write vault secrets into the target .env file."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Scope to materialize (resolved from cwd when omitted).")
    var scope: String?

    @Flag(name: .long, help: "Overwrite differing owned lines without prompting.")
    var force: Bool = false

    func run() async throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        do { try _run(cwd: cwd) } catch { ErrorReporter.report(error, json: global.json) }
    }

    // MARK: - Internal for testing

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
        // swiftlint:disable:next pattern_matching_keywords
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
