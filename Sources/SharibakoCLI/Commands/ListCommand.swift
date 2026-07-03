import ArgumentParser
import Foundation
import SharibakoCore

/// Lists scope or shared-entry IDs.
///
/// Default: lists every scope in the vault.
/// With `--shared`: lists every shared entry instead.
struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List scope or shared-entry IDs."
    )

    @OptionGroup var global: GlobalOptions

    /// Switch output to shared entries instead of scopes.
    @Flag(help: "List shared entries instead of scopes.")
    var shared: Bool = false

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
    /// Renders shared-entry IDs under `--shared`, scope IDs otherwise; JSON
    /// arrays under `--json`, one ID per line (or a placeholder) in plain mode.
    func composeOutput(vault: VaultCore, renderer: OutputRenderer) throws -> String {
        if shared {
            let ids = try vault.listShared()
            if renderer.json {
                return try renderer.encodeJSON(ids)
            }
            if ids.isEmpty {
                return "No shared entries."
            }
            return ids.joined(separator: "\n")
        }
        let ids = try vault.listScopes().map(\.identity)
        if renderer.json {
            return try renderer.encodeJSON(ids)
        }
        if ids.isEmpty {
            return "No scopes."
        }
        return ids.joined(separator: "\n")
    }
}
