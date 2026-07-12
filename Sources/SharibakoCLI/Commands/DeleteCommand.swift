import ArgumentParser
import Foundation
import SharibakoCore

/// Deletes a scope, a single key within a scope, or — with `--shared` — a shared entry.
///
/// Asks for confirmation unless `--yes` is supplied. No age key required — every
/// deletion removes files, none decrypts. Deleting a shared entry that other
/// scopes link to is refused unless `--force` is given (which orphans the linkers).
struct DeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a scope, a key within a scope, or a shared entry (--shared).",
        discussion: """
            Removes a scope (scopes/<id>/ and all its secrets), a single key within \
            a scope when a second argument is given (scopes/<scope>/<key>.age or \
            .link), or - with --shared - a shared entry (shared/<id>.age). Deletion \
            only ever touches the vault: .sharibako markers in your projects and any \
            already-materialized .env files are left exactly where they are (markers \
            become orphans the next scan surfaces; use 'sharibako clean' first if you \
            want the .env values gone too). The removal is not committed - run \
            'sharibako sync' to commit it. It stays in git history, so a deletion is \
            recoverable.

            No age key is required and no Touch ID fires - deletion removes files, it \
            never decrypts them. It asks for confirmation first unless --yes is \
            given; when stdin is not a terminal there is nobody to answer, so --yes \
            is required and its absence is a hard error rather than a silent skip.

            Deleting a key that is a link removes only the pointer - the shared entry \
            it named is untouched. A shared entry that other scopes still link to is \
            refused by default - deleting it would leave those links dangling - and \
            the referencing scope/key pairs are named so you can 'sharibako unlink' \
            them first (that keeps the value locally). Pass --force to delete anyway \
            and orphan them.

            EXAMPLES

            Delete a scope, with a prompt:
              sharibako delete kanyo-dev

            Delete a single key within a scope:
              sharibako delete kanyo-dev OPENAI_API_KEY

            Delete a scope non-interactively (in a script):
              sharibako delete kanyo-dev --yes

            Delete a shared entry, orphaning any scopes that link it:
              sharibako delete --shared openai-personal --force --yes

            EXIT CODES

            Exits 130 when a human declines the confirmation, 2 when confirmation \
            is required but stdin is not a terminal and --yes was not passed, and 2 \
            when a shared entry is still linked and --force was not passed.
            """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Scope ID to delete, or shared-entry ID when --shared is set.")
    var id: String

    @Argument(help: "Optional key within the scope to delete instead of the whole scope.")
    var key: String?

    @Flag(name: .long, help: "Delete a shared entry instead of a scope.")
    var shared: Bool = false

    @Flag(name: .long, help: "Skip the confirmation prompt (required when stdin is not a terminal).")
    var yes: Bool = false

    @Flag(name: .long, help: "For --shared: delete even if scopes still link it, orphaning them.")
    var force: Bool = false

    func run() async throws {
        do { try _run() } catch { ErrorReporter.report(error, json: global.json) }
    }

    // MARK: - Internal for testing

    // _run: leading-underscore testable-entry-point convention (.swift-format NoLeadingUnderscores: false).
    // swiftlint:disable:next identifier_name
    func _run(
        isInteractive: Bool = TerminalDetector.isInteractiveInput,
        lineReader: () -> String? = { readLine() }
    ) throws {
        let vaultURL = try VaultLocator.resolve(globalFlag: global.vaultURL)
        // Keyless: deletion removes files, it never decrypts, so no age identity
        // and no Touch ID.
        let vault = try VaultCore(vaultURL: vaultURL)

        if !yes {
            // Without a terminal there is nobody to answer the prompt — fail
            // loudly instead of proceeding on a destructive action (the clean
            // precedent, ho-04.11).
            guard isInteractive else {
                throw CLIError.promptRequiresTTY(command: "delete", flag: "--yes")
            }
            guard confirm(vault: vault, lineReader: lineReader) else {
                throw CLIError.aborted
            }
        }

        let renderer = OutputRenderer(json: global.json, color: !global.json && TerminalDetector.isColorTerminal)
        if shared {
            try vault.deleteSharedEntry(id, force: force)
            print(try rendered(kind: "shared", label: "shared entry \"\(id)\"", renderer: renderer))
        } else if let key {
            try vault.deleteSecret(key, inScope: id)
            print(try rendered(kind: "key", label: "key \"\(id)/\(key)\"", renderer: renderer))
        } else {
            try vault.deleteScope(id)
            print(try rendered(kind: "scope", label: "scope \"\(id)\"", renderer: renderer))
        }
    }

    private func confirm(vault: VaultCore, lineReader: () -> String?) -> Bool {
        let prompt: String
        if shared {
            prompt = "About to delete shared entry \"\(id)\". Continue? [y/N] "
        } else if let key {
            prompt = "About to delete key \"\(id)/\(key)\". Continue? [y/N] "
        } else {
            let count = (try? vault.inspect(id).count) ?? 0
            prompt =
                "About to delete scope \"\(id)\" and its \(count) secret(s). "
                + "Materialized .env files and markers are left in place. Continue? [y/N] "
        }
        // Prompt to stderr — stdout may be piped (the clean/get precedent).
        fputs(prompt, stderr)
        let answer = (lineReader() ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return answer == "y" || answer == "yes"
    }

    private func rendered(kind: String, label: String, renderer: OutputRenderer) throws -> String {
        if renderer.json {
            let value = kind == "key" ? "\(id)/\(key ?? "")" : id
            return try renderer.encodeJSON(["deleted": [kind: value]])
        }
        return "Deleted \(label). Run `sharibako sync` to commit the removal."
    }
}
