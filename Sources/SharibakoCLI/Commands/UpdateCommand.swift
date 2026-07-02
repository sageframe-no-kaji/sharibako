import ArgumentParser
import Foundation
import SharibakoCore

/// Reads hand-edited values from the target `.env` and writes them back into the vault.
///
/// Scope may be omitted when standing inside a project directory with a `.sharibako`
/// marker. Non-owned lines are ignored. Touch ID fires once per invocation on the
/// decrypt path (to compare existing vault values).
struct UpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Push hand-edited .env values back into the vault."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Scope to update (resolved from cwd when omitted).")
    var scope: String?

    func run() async throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        do { try _run(cwd: cwd) } catch { ErrorReporter.report(error, json: global.json) }
    }

    // MARK: - Internal for testing

    // swiftlint:disable:next identifier_name
    func _run(cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) throws {
        let vaultURL = try VaultLocator.resolve(globalFlag: global.vaultURL)
        let provider = VaultLocator.resolveProvider(globalFlag: global.ageKeyURL)
        let handle = try provider.loadIdentity(reason: "Update vault from .env")
        defer { handle.release() }
        let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: handle.url)
        let materializer = Materializer(vaultCore: vault, vaultURL: vaultURL)

        let (scopeID, discovered) = try ScopeResolver.resolve(
            explicit: scope, startingFrom: cwd, materializer: materializer
        )
        let marker = try discovered ?? materializer.resolveMarker(forScope: scopeID, scanRoots: [cwd])
        let result = try materializer.update(scopeID: scopeID, marker: marker)
        try renderResult(result)
    }

    private func renderResult(_ result: UpdateResult) throws {
        switch result {
        // swiftlint:disable:next pattern_matching_keywords
        case .updated(let keys, let warnings):
            print("Updated \(keys.count) key(s): \(keys.joined(separator: ", "))")
            emitWarnings(warnings)
        case .noChanges(let warnings):
            print("No changes")
            emitWarnings(warnings)
        case .fileMissing(let path):
            fputs("Warning: No .env at \(path.path) to read\n", stderr)
            throw CLIError.updateFileMissing
        }
    }

    private func emitWarnings(_ warnings: [ParseWarning]) {
        for warning in warnings {
            fputs("Warning: Line \(warning.lineNumber): \(warning.reason)\n", stderr)
        }
    }
}
