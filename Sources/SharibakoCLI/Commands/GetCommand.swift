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
        abstract: "Decrypt and print a secret value to stdout.",
        discussion: """
            Decrypts one secret and prints its value to stdout, followed by a \
            trailing newline (so shell command substitution strips it cleanly). \
            Touch ID fires once per invocation. If the key is a link, the value \
            of the shared entry it points at is printed.

            SECURITY

            'get' emits a plaintext secret to stdout. If stdout is a terminal, the \
            value is visible on screen and captured in scrollback; if it is \
            redirected or piped, the value goes wherever the pipe goes. The value \
            does NOT enter shell history (it is never on your command line). Use \
            'get' when you need to paste a value somewhere Sharibako does not \
            integrate - a web form, a partner's chat. For feeding secrets to a \
            command you launch, prefer 'sharibako run', which never renders the \
            value at all. Clear terminal scrollback after use, and do not pipe \
            'get' into files you will not clean up.

            EXAMPLES

            Capture a value into a shell variable (newline stripped):
              TOKEN="$(sharibako get kanyo-dev DEPLOY_TOKEN)"

            Print a value to paste elsewhere:
              sharibako get kanyo-dev OPENAI_API_KEY

            EXIT CODES

            Exits 2 when the scope or key does not exist, 4 on a decryption \
            failure, 6 on a Keychain/Touch ID failure.
            """
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
