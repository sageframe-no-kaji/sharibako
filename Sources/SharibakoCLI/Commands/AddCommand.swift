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
        abstract: "Encrypt and add a new secret to a scope.",
        discussion: """
            Encrypts a value and stores it as a new scope-local secret \
            (<KEY>.age) under the given scope. Touch ID fires once to unlock the \
            age key. 'add' is for a NEW key: it refuses to overwrite an existing \
            one unless --force is given - use 'sharibako rotate' to change the \
            value of a key that already exists, and 'sharibako link' to point a \
            key at a shared entry instead of storing its own value.

            HOW THE VALUE ENTERS

            The value can arrive three ways, with different exposure. With neither \
            --value nor --from-stdin on a terminal, Sharibako prompts with input \
            hidden (nothing lands in shell history or on screen) - the hygienic \
            default. --from-stdin reads the value from a pipe, exposing only \
            whatever produced the pipe. --value <v> puts the secret on your \
            command line, where it lands in shell history and is visible in 'ps' \
            for the duration of the run; use it in scripts that already hold the \
            value, not interactively.

            EXAMPLES

            Add a project-local secret, prompted with hidden input:
              sharibako add kanyo-dev DATABASE_URL

            Pipe a value in from another tool, nothing in argv or history:
              op read "op://Personal/OpenAI/key" | sharibako add kanyo-dev OPENAI_API_KEY --from-stdin

            Overwrite an existing key deliberately, with a note:
              sharibako add kanyo-dev API_TOKEN --value "..." --force --notes "rotated by ops"

            EXIT CODES

            Exits 2 when the key already exists without --force, 4 on an age \
            encryption failure. See sharibako(1) for the full taxonomy.
            """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Scope to add the secret to.")
    var scope: String

    @Argument(help: "Secret key name (e.g. DATABASE_URL).")
    var key: String

    @Option(
        name: .long,
        help: "Plaintext value. Prefer the hidden prompt or --from-stdin; --value leaks into shell history and 'ps'."
    )
    var value: String?

    @Flag(name: .customLong("from-stdin"), help: "Read the value from stdin (e.g. piped from another tool).")
    var fromStdin: Bool = false

    @Option(name: .long, help: "Optional notes stored (encrypted) alongside the value.")
    var notes: String?

    @Flag(name: .long, help: "Overwrite an existing key (add otherwise refuses, exit 2).")
    var force: Bool = false

    func run() async throws {
        do { try _run() } catch { ErrorReporter.report(error, json: global.json) }
    }

    // MARK: - Internal for testing

    // _run: leading-underscore testable-entry-point convention (.swift-format NoLeadingUnderscores: false).
    // swiftlint:disable:next identifier_name
    func _run(valuePrompt: (() throws -> String)? = SecureValuePrompt.defaultPrompt) throws {
        let plaintext = try ValueInput(
            value: value, fromStdin: fromStdin, securePrompt: valuePrompt
        ).read()
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
            // Encoded, not interpolated — scope and key are user-supplied argv
            // and may contain characters that break hand-built JSON.
            let renderer = OutputRenderer(json: true, color: false)
            print(try renderer.encodeJSON(["added": ["scope": scope, "key": key]]))
        } else {
            print("Added \(scope)/\(key)")
        }
    }
}
