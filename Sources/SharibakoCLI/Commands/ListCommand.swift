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
        abstract: "List scope or shared-entry IDs.",
        discussion: """
            Prints the IDs in the vault, one per line: every scope by default, or \
            every shared-pool entry with --shared. It is the quick "what's in \
            here" verb - a bare inventory of names. For per-scope detail (secret \
            counts, key kinds, drift), use 'sharibako status'.

            No age key is required; 'list' reads directory names only and never \
            decrypts. --json emits a plain array of IDs.

            EXAMPLES

            List every scope:
              sharibako list

            List the shared pool (targets for 'link'):
              sharibako list --shared

            Machine-readable:
              sharibako list --json
            """
    )

    @OptionGroup var global: GlobalOptions

    /// Switch output to shared entries instead of scopes.
    @Flag(help: "List shared-pool entries instead of scopes.")
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
