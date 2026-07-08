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
        abstract: "Convert a linked key back into a scope-local secret.",
        discussion: """
            Dissolves a link, giving the scope its own copy of the value. It \
            decrypts the shared entry the key currently points at and re-encrypts \
            that value as a scope-local secret (<KEY>.age), replacing the .link \
            pointer - so the key keeps its current value but stops tracking the \
            shared entry. After this, rotating the shared entry no longer affects \
            this scope. It is the inverse of 'sharibako link'. Touch ID fires once \
            (the value must be decrypted and re-encrypted). The shared entry \
            itself is left in place for other scopes.

            EXAMPLES

            Detach a project's key from the shared pool, keeping the value:
              sharibako unlink kanyo-dev OPENAI_API_KEY

            EXIT CODES

            Exits 2 when the scope or key does not exist or the key is not linked, \
            4/6 on decrypt/Keychain failures.
            """
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
