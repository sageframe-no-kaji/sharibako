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

/// JSON shape for a marker that failed to load in `scan --json` output (ho-04.11).
struct ScanFailureEntry: Codable, Sendable {
    /// Absolute path of the `.sharibako` marker file that failed to load.
    let path: String
    /// Load-failure reason.
    let reason: String
}

/// JSON root for `scan --json` output: loaded markers plus load failures (ho-04.11).
struct ScanJSONResult: Codable, Sendable {
    /// Markers that loaded and validated.
    let markers: [ScanEntry]
    /// Markers that failed to load.
    let failures: [ScanFailureEntry]
}

/// Walks a directory tree for `.sharibako` markers.
///
/// Defaults to the current working directory when `<root>` is omitted.
struct ScanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Find .sharibako markers below a directory.",
        discussion: """
            Walks a directory tree and reports every .sharibako marker it finds, \
            printing the scope, marker path, and materialize target for each - a \
            map of which project directories on disk are bound to which scopes. \
            Defaults to the current directory when no root is given. Markers that \
            fail to load or validate are surfaced as warnings on stderr (or in the \
            'failures' array under --json) so stdout stays a clean, pipeable table.

            'scan' is discovery across many directories; 'status' inventories the \
            vault itself; 'list' just names scopes. No age key is required - 'scan' \
            reads marker files only and never decrypts.

            EXAMPLES

            Map every marked project under a code tree:
              sharibako scan ~/Projects

            Scan the current directory, machine-readable:
              sharibako scan --json
            """
    )

    @OptionGroup var global: GlobalOptions

    /// Root directory to search.
    ///
    /// Defaults to the current working directory when omitted.
    @Argument(help: "Directory to scan (defaults to current directory).")
    var root: String?

    func run() async throws {
        do { try _run() } catch { ErrorReporter.report(error, json: global.json) }
    }

    private func _run() throws {
        let vaultURL = try VaultLocator.resolve(globalFlag: global.vaultURL)
        let vault = try VaultCore(vaultURL: vaultURL)
        let materializer = Materializer(vaultCore: vault, vaultURL: vaultURL)
        let renderer = OutputRenderer(json: global.json, color: !global.json && TerminalDetector.isColorTerminal)
        let result = try fetchResult(materializer: materializer)
        // Human mode: failures go to stderr as warnings so stdout stays a
        // clean table; JSON mode carries them in the payload instead.
        if !renderer.json {
            for failure in result.failures {
                fputs(renderer.warn("Skipped \(failure.path): \(failure.reason)") + "\n", stderr)
            }
        }
        print(try composeOutput(result: result, renderer: renderer))
    }

    /// Builds the full command output (print-free seam for tests).
    ///
    /// `{markers, failures}` object under `--json`, a placeholder when nothing
    /// was found, and a SCOPE/MARKER/TARGET table otherwise (failures print to
    /// stderr in `_run`, not here — stdout stays pipeable).
    func composeOutput(result: ScanJSONResult, renderer: OutputRenderer) throws -> String {
        if renderer.json {
            return try renderer.encodeJSON(result)
        }

        guard !result.markers.isEmpty else {
            return "No .sharibako markers found."
        }

        return renderer.table(
            headers: ["SCOPE", "MARKER", "TARGET"],
            rows: result.markers.map { [$0.scope, $0.path, $0.target] }
        )
    }

    /// Runs the scan and converts the report to output entries.
    ///
    /// Exposed for tests to verify data without capturing stdout.
    func fetchResult(materializer: Materializer) throws -> ScanJSONResult {
        let rootURL: URL
        if let rootPath = root {
            rootURL = URL(fileURLWithPath: rootPath)
        } else {
            rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
        let report = try materializer.scan(roots: [rootURL])
        return ScanJSONResult(
            markers: report.markers.map {
                ScanEntry(path: $0.markerURL.path, scope: $0.scope, target: $0.targetURL.path)
            },
            failures: report.failures.map {
                ScanFailureEntry(path: $0.markerURL.path, reason: $0.reason)
            }
        )
    }
}
