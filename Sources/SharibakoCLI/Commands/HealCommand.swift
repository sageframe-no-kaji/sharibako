import ArgumentParser
import Foundation
import SharibakoCore

/// JSON shape for a single key drift entry in `heal --json` output.
struct HealKeyEntry: Codable, Sendable {
    /// Secret key name.
    let key: String
    /// Drift status: `"match"`, `"fileMissing"`, or `"fileValueDiffers"`.
    let status: String
    /// SHA-256 hex digest of the vault value when status is `"fileValueDiffers"`.
    let vaultSha256: String?
    /// SHA-256 hex digest of the file value when status is `"fileValueDiffers"`.
    let fileSha256: String?
}

/// JSON root for `heal --json` output.
struct HealResult: Codable, Sendable {
    /// Scope the report covers.
    let scopeID: String
    /// Absolute path of the target `.env` file.
    let path: String
    /// Per-key drift entries.
    let owned: [HealKeyEntry]
}

/// Reports drift between the vault and the materialized `.env` file.
///
/// Requires the age key to decrypt vault values. Scope resolution walks up from
/// cwd when `<scope>` is omitted (same as git's `.git/` discovery).
struct HealCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "heal",
        abstract: "Report drift between the vault and materialized .env."
    )

    @OptionGroup var global: GlobalOptions

    /// Scope to inspect.
    ///
    /// When absent, resolved from the nearest `.sharibako` marker walking up from cwd.
    @Argument(help: "Scope to inspect (resolved from cwd when omitted).")
    var scope: String?

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
        let handle = try provider.loadIdentity(reason: "Read vault secrets for heal")
        defer { handle.release() }

        let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: handle.url)
        let materializer = Materializer(vaultCore: vault, vaultURL: vaultURL)

        let marker = try resolveMarker(materializer: materializer, cwd: cwd)
        let report = try materializer.heal(marker: marker)
        let renderer = OutputRenderer(json: global.json, color: !global.json && TerminalDetector.isColorTerminal)

        if global.json {
            let result = buildHealResult(from: report)
            print(try renderer.encodeJSON(result))
            return
        }

        renderHumanReport(report: report, renderer: renderer)
    }

    /// Resolves the marker from an explicit scope argument or by cwd walk-up.
    func resolveMarker(materializer: Materializer, cwd: URL) throws -> ScopeMarker {
        if let scopeID = scope {
            return try materializer.resolveMarker(forScope: scopeID, scanRoots: [cwd])
        }
        return try materializer.resolveMarker(startingFrom: cwd)
    }

    /// Converts a `DriftReport` to the JSON-serializable `HealResult`.
    func buildHealResult(from report: DriftReport) -> HealResult {
        let entries = report.owned.map { drift -> HealKeyEntry in
            switch drift {
            case .match(let key):
                return HealKeyEntry(key: key, status: "match", vaultSha256: nil, fileSha256: nil)
            case .fileMissing(let key):
                return HealKeyEntry(key: key, status: "fileMissing", vaultSha256: nil, fileSha256: nil)
            case .fileValueDiffers(let key, let vaultSha256, let fileSha256):
                return HealKeyEntry(
                    key: key, status: "fileValueDiffers", vaultSha256: vaultSha256, fileSha256: fileSha256)
            }
        }
        return HealResult(scopeID: report.scopeID, path: report.path.path, owned: entries)
    }

    // MARK: - Human rendering

    private func renderHumanReport(report: DriftReport, renderer: OutputRenderer) {
        let useColor = renderer.color
        let rows = report.owned.map { drift -> [String] in
            switch drift {
            case .match(let key):
                return [colorSymbol("✓", ansi: "\u{1B}[32m", enabled: useColor), key, "match"]
            case .fileMissing(let key):
                return [colorSymbol("✗", ansi: "\u{1B}[31m", enabled: useColor), key, "file missing"]
            case .fileValueDiffers(let key, let vaultSha256, let fileSha256):
                let diff = "vault:\(vaultSha256.prefix(8))… file:\(fileSha256.prefix(8))…"
                return [colorSymbol("~", ansi: "\u{1B}[33m", enabled: useColor), key, diff]
            }
        }
        print(renderer.table(headers: ["", "KEY", "STATUS"], rows: rows))
        for warning in report.parseWarnings {
            fputs(renderer.warn("Line \(warning.lineNumber): \(warning.reason)") + "\n", stderr)
        }
    }
}

/// Returns `symbol` wrapped in an ANSI escape sequence when `enabled`, plain text otherwise.
private func colorSymbol(_ symbol: String, ansi: String, enabled: Bool) -> String {
    guard enabled else { return symbol }
    return "\(ansi)\(symbol)\u{1B}[0m"
}
