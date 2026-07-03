import ArgumentParser
import Foundation
import SharibakoCore

/// JSON shape for a single scope entry in `status --json` output.
struct ScopeStatusEntry: Codable, Sendable {
    /// Scope identity (directory name in `scopes/`).
    let identity: String
    /// Scope category.
    let type: String
    /// Optional human-friendly display name.
    let displayName: String?
    /// Number of secrets (`.age` and `.link` files) in the scope.
    let secretCount: Int
}

/// Prints vault and scope state without decrypting.
///
/// With no argument: lists every scope and the count of its secrets.
/// With `<scope>`: shows metadata + secret keys for that scope.
struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show vault and scope state."
    )

    @OptionGroup var global: GlobalOptions

    /// Limit output to a single scope.
    @Argument(help: "Show status for a specific scope only.")
    var scope: String?

    func run() async throws {
        do { try _run() } catch { ErrorReporter.report(error, json: global.json) }
    }

    private func _run() throws {
        let vaultURL = try VaultLocator.resolve(globalFlag: global.vaultURL)
        let vault = try VaultCore(vaultURL: vaultURL)
        let renderer = OutputRenderer(json: global.json, color: !global.json && TerminalDetector.isColorTerminal)
        print(try composeOutput(vault: vault, renderer: renderer))
    }

    /// Builds the full command output (print-free seam for tests).
    ///
    /// The scope filter runs before any rendering branch: previously the JSON
    /// path returned every scope with the argument silently ignored, and an
    /// unknown scope on an empty vault exited 0.
    func composeOutput(vault: VaultCore, renderer: OutputRenderer) throws -> String {
        let entries = try fetchEntries(vault: vault)

        if let scopeID = scope {
            let match = entries.filter { $0.identity == scopeID }
            if match.isEmpty {
                throw VaultError.scopeNotFound(id: scopeID)
            }
            if renderer.json {
                // Same array shape as the no-argument form, filtered.
                return try renderer.encodeJSON(match)
            }
            let secrets = try vault.inspect(scopeID)
            return renderer.table(
                headers: ["KEY", "KIND"],
                rows: secrets.map { info in
                    let kind: String
                    switch info.kind {
                    case .value: kind = "local"
                    case .link(let sharedID): kind = "→ \(sharedID)"
                    }
                    return [info.key, kind]
                }
            )
        }

        if renderer.json {
            return try renderer.encodeJSON(entries)
        }

        guard !entries.isEmpty else {
            return "No scopes in vault."
        }

        return renderer.table(
            headers: ["SCOPE", "TYPE", "SECRETS"],
            rows: entries.map { [$0.identity, $0.type, String($0.secretCount)] }
        )
    }

    /// Builds the status entries for every scope in the vault.
    ///
    /// Exposed for tests to verify data without capturing stdout.
    func fetchEntries(vault: VaultCore) throws -> [ScopeStatusEntry] {
        let scopes = try vault.listScopes()
        return try scopes.map { meta in
            let secrets = try vault.inspect(meta.identity)
            return ScopeStatusEntry(
                identity: meta.identity,
                type: meta.type.rawValue,
                displayName: meta.displayName,
                secretCount: secrets.count
            )
        }
    }
}
