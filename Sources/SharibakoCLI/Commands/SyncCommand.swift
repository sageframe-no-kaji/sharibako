import ArgumentParser
import Foundation
import SharibakoCore

/// Commits pending vault changes, pushes to the remote, and pulls incoming commits.
///
/// Does not require the age key — all operations are git-level file commits with
/// no secret decryption.
struct SyncCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Commit, push, and pull the vault git repository."
    )

    @OptionGroup var global: GlobalOptions

    @Flag(name: .customLong("no-push"), help: "Skip the push step.")
    var noPush: Bool = false

    @Flag(name: .customLong("no-pull"), help: "Skip the pull step.")
    var noPull: Bool = false

    @Option(name: .shortAndLong, help: "Commit message (default: \"sharibako auto-commit\").")
    var message: String?

    func run() async throws {
        do { try _run() } catch { ErrorReporter.report(error, json: global.json) }
    }

    // MARK: - Internal for testing

    // swiftlint:disable:next identifier_name
    func _run() throws {
        let vaultURL = try VaultLocator.resolve(globalFlag: global.vaultURL)
        let conduit = try Conduit(vaultURL: vaultURL)

        let commitMsg = message ?? "sharibako auto-commit"
        let commitResult = try conduit.commit(message: commitMsg)
        let sha = commitSHA(from: commitResult)

        var pushedCount = 0
        var pulledCount = 0

        if !noPush {
            pushedCount = try handlePush(conduit: conduit)
        }

        if !noPull {
            pulledCount = try handlePull(conduit: conduit)
        }

        print("Synced: committed \(sha), pushed \(pushedCount), pulled \(pulledCount)")
    }

    private func commitSHA(from result: CommitResult) -> String {
        switch result {
        case .success(let sha): return sha
        case .nothingToCommit:
            print("nothing to commit")
            return "(none)"
        }
    }

    private func handlePush(conduit: Conduit) throws -> Int {
        let result = try conduit.push()
        switch result {
        case .success(let count): return count
        case .upToDate: return 0
        case .noRemote: return 0
        case .rejected(let reason):
            fputs("Push rejected: \(reason)\n", stderr)
            fputs("Hint: resolve the conflict remotely, then run `sharibako sync` again.\n", stderr)
            throw CLIError.syncRejected
        }
    }

    private func handlePull(conduit: Conduit) throws -> Int {
        let result = try conduit.pull()
        switch result {
        case .success(let count): return count
        case .upToDate: return 0
        case .noRemote: return 0
        case .abortedConflict(let conflicts):
            fputs("Pull conflict (merge aborted — vault is clean):\n", stderr)
            for conflict in conflicts {
                fputs("  \(conflict.path.lastPathComponent)\n", stderr)
                if !conflict.localSHA.isEmpty {
                    fputs("    local:  \(conflict.localSHA)\n", stderr)
                }
                if !conflict.remoteSHA.isEmpty {
                    fputs("    remote: \(conflict.remoteSHA)\n", stderr)
                }
            }
            fputs("Hint: use `git show <sha>` to inspect each version, then run `sharibako sync` again.\n", stderr)
            throw CLIError.syncConflict
        }
    }
}
