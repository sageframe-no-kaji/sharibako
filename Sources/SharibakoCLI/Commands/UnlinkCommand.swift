import ArgumentParser
import Foundation
import SharibakoCore

/// Converts a linked key back into a scope-local encrypted value.
///
/// Decrypts the shared entry and re-encrypts the value under the scope key.
/// Touch ID fires once per invocation.
struct UnlinkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unlink",
        abstract: "Convert a linked key back into a scope-local secret."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Scope containing the linked key.")
    var scope: String

    @Argument(help: "Key whose link to dissolve.")
    var key: String

    func run() async throws {
        do { try _run() } catch { ErrorReporter.report(error, json: global.json) }
    }

    // MARK: - Internal for testing

    // _run: leading-underscore testable-entry-point convention (.swift-format NoLeadingUnderscores: false).
    // swiftlint:disable:next identifier_name
    func _run() throws {
        let vaultURL = try VaultLocator.resolve(globalFlag: global.vaultURL)
        let provider = VaultLocator.resolveProvider(globalFlag: global.ageKeyURL)
        let handle = try provider.loadIdentity(reason: "Unlink \(scope)/\(key)")
        defer { handle.release() }
        let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: handle.url)
        try vault.unlink(key, inScope: scope)
        print("Unlinked \(scope)/\(key) (now scope-local)")
    }
}
