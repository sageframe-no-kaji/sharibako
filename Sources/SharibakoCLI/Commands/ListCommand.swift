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

        if shared {
            let ids = try vault.listShared()
            if global.json {
                print(try renderer.encodeJSON(ids))
            } else if ids.isEmpty {
                print("No shared entries.")
            } else {
                for id in ids { print(id) }
            }
        } else {
            let scopes = try vault.listScopes()
            let ids = scopes.map(\.identity)
            if global.json {
                print(try renderer.encodeJSON(ids))
            } else if ids.isEmpty {
                print("No scopes.")
            } else {
                for id in ids { print(id) }
            }
        }
    }
}
