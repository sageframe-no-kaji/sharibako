import ArgumentParser
import Foundation
import SharibakoCore

/// JSON shape for a single marker entry in `scan --json` output.
struct ScanEntry: Codable, Sendable {
    /// Absolute path of the `.sharibako` marker file.
    let path: String
    /// Scope ID recorded in the marker.
    let scope: String
    /// Absolute path of the target `.env` file.
    let target: String
}

/// Walks a directory tree for `.sharibako` markers.
///
/// Defaults to the current working directory when `<root>` is omitted.
struct ScanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Find .sharibako markers below a directory."
    )

    @OptionGroup var global: GlobalOptions

    /// Root directory to search.
    ///
    /// Defaults to the current working directory when omitted.
    @Argument(help: "Directory to scan (defaults to current directory).")
    var root: String?

    func run() async throws {
        let vaultURL = try VaultLocator.resolve(globalFlag: global.vaultURL)
        let vault = try VaultCore(vaultURL: vaultURL)
        let materializer = Materializer(vaultCore: vault, vaultURL: vaultURL)
        let entries = try fetchEntries(materializer: materializer)

        let renderer = OutputRenderer(json: global.json, color: !global.json && TerminalDetector.isColorTerminal)

        if global.json {
            print(try renderer.encodeJSON(entries))
            return
        }

        guard !entries.isEmpty else {
            print("No .sharibako markers found.")
            return
        }

        print(
            renderer.table(
                headers: ["SCOPE", "MARKER", "TARGET"],
                rows: entries.map { [$0.scope, $0.path, $0.target] }
            ))
    }

    /// Builds scan entries from the resolved root directory.
    ///
    /// Exposed for tests to verify data without capturing stdout.
    func fetchEntries(materializer: Materializer) throws -> [ScanEntry] {
        let rootURL: URL
        if let rootPath = root {
            rootURL = URL(fileURLWithPath: rootPath)
        } else {
            rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
        let markers = try materializer.scan(roots: [rootURL])
        return markers.map {
            ScanEntry(path: $0.markerURL.path, scope: $0.scope, target: $0.targetURL.path)
        }
    }
}
