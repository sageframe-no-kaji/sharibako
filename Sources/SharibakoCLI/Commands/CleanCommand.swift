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
        abstract: "Remove owned secrets from the target .env file."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Scope to clean (resolved from cwd when omitted).")
    var scope: String?

    @Flag(name: .long, help: "Skip the confirmation prompt.")
    var yes: Bool = false

    func run() async throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        do { try _run(cwd: cwd) { readLine() } } catch {
            ErrorReporter.report(error, json: global.json)
        }
    }

    // MARK: - Internal for testing

    // swiftlint:disable:next identifier_name
    func _run(
        cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
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
            guard confirmClean(marker: marker, vault: vault, lineReader: lineReader) else { return }
        }

        let result = try materializer.clean(marker: marker)
        renderResult(result)
    }

    private func confirmClean(marker: ScopeMarker, vault: VaultCore, lineReader: () -> String?) -> Bool {
        let count = (try? vault.inspect(marker.scope).count) ?? 0
        print("About to remove \(count) owned key(s) from \(marker.targetURL.path). Continue? [y/N]")
        let answer = (lineReader() ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return answer == "y" || answer == "yes"
    }

    private func renderResult(_ result: CleanResult) {
        switch result {
        // swiftlint:disable:next pattern_matching_keywords
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
