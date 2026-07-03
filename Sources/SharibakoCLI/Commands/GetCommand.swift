import ArgumentParser
import Foundation
import SharibakoCore

/// Decrypts and prints one secret value to stdout.
///
/// Touch ID (or passphrase on Linux) fires once per invocation. The raw value
/// is printed with a trailing newline so shell command substitution
/// (`$(sharibako get scope key)`) strips it automatically.
struct GetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Decrypt and print a secret value to stdout."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Scope that owns the secret.")
    var scope: String

    @Argument(help: "Secret key to retrieve.")
    var key: String

    func run() async throws {
        do { try _run() } catch { ErrorReporter.report(error, json: global.json) }
    }

    // MARK: - Internal for testing

    /// Decrypts and returns the plaintext value without printing it.
    func fetchValue() throws -> String {
        let vaultURL = try VaultLocator.resolve(globalFlag: global.vaultURL)
        let provider = VaultLocator.resolveProvider(globalFlag: global.ageKeyURL)
        let handle = try provider.loadIdentity(reason: "Decrypt sharibako secret \(key)")
        defer { handle.release() }
        let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: handle.url)
        return try vault.getValue(key, inScope: scope)
    }

    // _run: leading-underscore testable-entry-point convention (.swift-format NoLeadingUnderscores: false).
    // swiftlint:disable:next identifier_name
    func _run() throws {
        print(try fetchValue())
    }
}
