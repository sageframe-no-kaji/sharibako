import ArgumentParser
import Foundation
import SharibakoCore

/// Rotates an existing secret to a new value.
///
/// Detects whether the key resolves through a `.link` to a shared entry and
/// rotates the shared entry if so. Touch ID fires once per invocation.
struct RotateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rotate",
        abstract: "Rotate an existing secret to a new value."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Scope that owns the secret.")
    var scope: String

    @Argument(help: "Secret key to rotate.")
    var key: String

    @Option(name: .long, help: "New plaintext value.")
    var value: String?

    @Flag(name: .customLong("from-stdin"), help: "Read new value from stdin.")
    var fromStdin: Bool = false

    func run() async throws {
        do { try _run() } catch { ErrorReporter.report(error, json: global.json) }
    }

    // MARK: - Internal for testing

    // _run: leading-underscore testable-entry-point convention (.swift-format NoLeadingUnderscores: false).
    // swiftlint:disable:next identifier_name
    func _run() throws {
        let newValue = try ValueInput(value: value, fromStdin: fromStdin).read()
        let vaultURL = try VaultLocator.resolve(globalFlag: global.vaultURL)
        let provider = VaultLocator.resolveProvider(globalFlag: global.ageKeyURL)
        let handle = try provider.loadIdentity(reason: "Rotate secret \(key)")
        defer { handle.release() }
        let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: handle.url)

        let infos = try vault.inspect(scope)
        guard let info = infos.first(where: { $0.key == key }) else {
            throw VaultError.secretNotFound(scope: scope, key: key)
        }

        switch info.kind {
        case .value:
            try vault.rotate(key, inScope: scope, newValue: newValue)
            print("Rotated \(scope)/\(key)")
        case .link(let sharedID):
            try vault.rotateShared(sharedID, newValue: newValue)
            print("Rotated shared entry \(sharedID) (via \(scope)/\(key))")
        }
    }
}
