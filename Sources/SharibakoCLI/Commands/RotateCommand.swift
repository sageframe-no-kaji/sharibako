import ArgumentParser
import Foundation
import SharibakoCore

/// Rotates an existing secret to a new value.
///
/// The scope/key form detects whether the key resolves through a `.link` to a
/// shared entry and rotates the shared entry if so. `--shared <id>` rotates a
/// shared entry directly — the only rotation path for an entry no scope links
/// yet (ho-04.10). Touch ID fires once per invocation.
struct RotateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rotate",
        abstract: "Rotate an existing secret to a new value."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Scope that owns the secret.")
    var scope: String?

    @Argument(help: "Secret key to rotate.")
    var key: String?

    @Option(name: .long, help: "Rotate a shared entry directly by ID (instead of scope/key).")
    var shared: String?

    @Option(name: .long, help: "New plaintext value.")
    var value: String?

    @Flag(name: .customLong("from-stdin"), help: "Read new value from stdin.")
    var fromStdin: Bool = false

    func validate() throws {
        if shared != nil {
            guard scope == nil, key == nil else {
                throw ValidationError("--shared cannot be combined with a scope/key.")
            }
        } else {
            guard scope != nil, key != nil else {
                throw ValidationError("Provide a scope and key, or --shared <id>.")
            }
        }
    }

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
        let subject = shared.map { "shared entry \($0)" } ?? "secret \(key ?? "")"
        let handle = try provider.loadIdentity(reason: "Rotate \(subject)")
        defer { handle.release() }
        let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: handle.url)

        if let sharedID = shared {
            try vault.rotateShared(sharedID, newValue: newValue)
            print("Rotated shared entry \(sharedID)")
            return
        }
        // validate() guarantees both are present on the scope/key path.
        guard let scope, let key else {
            throw ValidationError("Provide a scope and key, or --shared <id>.")
        }

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
