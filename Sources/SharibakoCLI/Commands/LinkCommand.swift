import ArgumentParser
import Foundation
import SharibakoCore

/// Creates a `.link` from a scope key to a shared entry.
///
/// No age key required — `.link` files are plaintext scope-ID pointers.
struct LinkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "link",
        abstract: "Link a scope key to an existing shared entry.",
        discussion: """
            Points a scope's key at a value in the shared pool by writing a \
            plaintext pointer file (<KEY>.link) naming the shared entry. Once \
            linked, the scope materializes (and runs with) whatever the shared \
            entry currently holds, so rotating that shared value once updates \
            every scope linked to it. This is the mechanism behind "rotate an \
            OpenAI key once, every project picks it up."

            No age key is required - a link is a name, not a value, so nothing is \
            decrypted and no Touch ID fires. The shared entry must already exist \
            (create one by choosing "move to shared" during 'init', or it appears \
            when a linked key is first rotated); 'sharibako list --shared' shows \
            the available entries. To dissolve a link and give the scope its own \
            copy of the value again, use 'sharibako unlink'.

            EXAMPLES

            Link a project's key to a shared entry:
              sharibako link kanyo-dev OPENAI_API_KEY openai-personal

            See what shared entries exist to link to:
              sharibako list --shared

            EXIT CODES

            Exits 2 when the named shared entry does not exist.
            """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Scope to add the link to.")
    var scope: String

    @Argument(help: "Key name for the link (e.g. OPENAI_API_KEY).")
    var key: String

    @Argument(help: "Shared entry ID to link to (see 'sharibako list --shared').")
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
