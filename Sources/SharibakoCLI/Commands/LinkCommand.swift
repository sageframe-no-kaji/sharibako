import ArgumentParser
import Foundation
import SharibakoCore

/// Creates a `.link` from a scope key to a shared entry.
///
/// No age key required — `.link` files are plaintext scope-ID pointers.
struct LinkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "link",
        abstract: "Link a scope key to an existing shared entry."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Scope to add the link to.")
    var scope: String

    @Argument(help: "Key name for the link.")
    var key: String

    @Argument(help: "Shared entry ID to link to.")
    var sharedID: String

    func run() async throws {
        do { try _run() } catch { ErrorReporter.report(error, json: global.json) }
    }

    // MARK: - Internal for testing

    // _run: leading-underscore testable-entry-point convention (.swift-format NoLeadingUnderscores: false).
    // swiftlint:disable:next identifier_name
    func _run() throws {
        let vaultURL = try VaultLocator.resolve(globalFlag: global.vaultURL)
        let vault = try VaultCore(vaultURL: vaultURL)

        let shared = try vault.listShared()
        guard shared.contains(sharedID) else {
            throw VaultError.sharedEntryNotFound(id: sharedID)
        }

        try vault.link(key, inScope: scope, toShared: sharedID)
        print("Linked \(scope)/\(key) → shared/\(sharedID)")
    }
}
