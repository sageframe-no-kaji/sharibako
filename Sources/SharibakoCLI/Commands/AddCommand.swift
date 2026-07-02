import ArgumentParser
import Foundation
import SharibakoCore

/// Encrypts and stores a new scope-local secret.
///
/// Refuses to overwrite an existing key unless `--force` is supplied.
/// Supply the value via `--value` or pipe it via `--from-stdin`; exactly one is required.
struct AddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Encrypt and add a new secret to a scope."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Scope to add the secret to.")
    var scope: String

    @Argument(help: "Secret key name.")
    var key: String

    @Option(name: .long, help: "Plaintext value to encrypt.")
    var value: String?

    @Flag(name: .customLong("from-stdin"), help: "Read value from stdin.")
    var fromStdin: Bool = false

    @Option(name: .long, help: "Optional notes stored alongside the value.")
    var notes: String?

    @Flag(name: .long, help: "Overwrite an existing key without prompting.")
    var force: Bool = false

    func run() async throws {
        do { try _run() } catch { ErrorReporter.report(error, json: global.json) }
    }

    // MARK: - Internal for testing

    // swiftlint:disable:next identifier_name
    func _run() throws {
        let plaintext = try ValueInput(value: value, fromStdin: fromStdin).read()
        let vaultURL = try VaultLocator.resolve(globalFlag: global.vaultURL)
        let provider = VaultLocator.resolveProvider(globalFlag: global.ageKeyURL)
        let handle = try provider.loadIdentity(reason: "Encrypt new secret \(key)")
        defer { handle.release() }
        let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: handle.url)

        _ = try vault.getScope(scope)

        if !force {
            let existing = try vault.inspect(scope)
            if existing.contains(where: { $0.key == key }) {
                throw CLIError.secretAlreadyExists(scope: scope, key: key)
            }
        }

        try vault.addSecret(key, value: plaintext, inScope: scope, notes: notes)

        if global.json {
            let payload = "{\"added\":{\"scope\":\"\(scope)\",\"key\":\"\(key)\"}}"
            print(payload)
        } else {
            print("Added \(scope)/\(key)")
        }
    }
}
