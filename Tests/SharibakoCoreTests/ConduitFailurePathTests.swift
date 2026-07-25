import Foundation
import Testing

@testable import SharibakoCore

/// Edge and failure-path tests for `Conduit`.
///
/// The states a vault's git repo can be in before it has any history, when a
/// file is asked about from outside the vault, and when git itself refuses.
///
/// These are reachable states, not hypotheticals — a vault created but never
/// synced has no commits, and a remote created but never pushed to has no
/// branch for the local one to track.
@Suite("Conduit failure paths")
struct ConduitFailurePathTests {
    /// Creates a bare repo at `url` and returns its path.
    private func makeBareRemote(at url: URL) throws -> String {
        let git = try Shell.findExecutable("git")
        let result = try Shell.run(git, ["init", "--bare", "--initial-branch=main", url.path])
        guard result.exitCode == 0 else {
            throw VaultError.gitInvocationFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        return url.path
    }

    // MARK: - log

    @Test("log returns an empty history on a repo with no commits yet")
    func logOnRepoWithoutCommits() throws {
        try VaultTestSupport.withEphemeralGitVault { vault in
            let conduit = try Conduit(vaultURL: vault)
            let fileURL = vault.appendingPathComponent("scopes/alpha/scope.yaml")

            #expect(try conduit.log(fileURL: fileURL).isEmpty)
        }
    }

    @Test("log falls back to the bare filename for a path outside the vault")
    func logForFileOutsideVault() throws {
        try VaultTestSupport.withEphemeralGitVault { vault in
            let conduit = try Conduit(vaultURL: vault)
            let outside = URL(fileURLWithPath: "/elsewhere/entirely/scope.yaml")

            // Nothing by that name is tracked, so the answer is an empty
            // history — the point is that it resolves rather than throwing.
            #expect(try conduit.log(fileURL: outside).isEmpty)
        }
    }

    // MARK: - initializeRepository

    @Test("initializeRepository reports git's failure when the directory is read-only")
    func initializeIntoReadOnlyDirectory() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            let fileManager = FileManager.default
            try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: vault.path)
            defer {
                try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vault.path)
            }

            let conduit = try Conduit(vaultURL: vault)
            let error = #expect(throws: VaultError.self) { try conduit.initializeRepository() }
            guard case .gitInvocationFailed = error else {
                Issue.record("expected gitInvocationFailed, got \(String(describing: error))")
                return
            }
        }
    }

    // MARK: - push

    @Test("push reports git's failure when origin is not a repository")
    func pushToNonRepository() throws {
        try VaultTestSupport.withEphemeralGitVault { vault in
            let conduit = try Conduit(vaultURL: vault)
            let placeholder = vault.appendingPathComponent(".gitkeep")
            try "".write(to: placeholder, atomically: true, encoding: .utf8)
            _ = try conduit.commit(message: "Initial vault setup")
            try conduit.setRemote("/nonexistent/not-a-repo.git")

            let error = #expect(throws: VaultError.self) { _ = try conduit.push() }
            guard case .gitInvocationFailed = error else {
                Issue.record("expected gitInvocationFailed, got \(String(describing: error))")
                return
            }
        }
    }

    // MARK: - pull

    @Test("pull reports git's failure when HEAD has no commits to name a branch from")
    func pullWithoutAnyCommits() throws {
        try VaultTestSupport.withEphemeralGitVault { vault in
            let remote = vault.deletingLastPathComponent()
                .appendingPathComponent("remote-\(UUID().uuidString).git")
            defer { try? FileManager.default.removeItem(at: remote) }
            let conduit = try Conduit(vaultURL: vault)
            try conduit.setRemote(try makeBareRemote(at: remote))

            let error = #expect(throws: VaultError.self) { _ = try conduit.pull() }
            guard case .gitInvocationFailed = error else {
                Issue.record("expected gitInvocationFailed, got \(String(describing: error))")
                return
            }
        }
    }

    @Test("pull reports git's failure when the remote has no branch to track")
    func pullWithoutRemoteBranch() throws {
        try VaultTestSupport.withEphemeralGitVault { vault in
            let remote = vault.deletingLastPathComponent()
                .appendingPathComponent("remote-\(UUID().uuidString).git")
            defer { try? FileManager.default.removeItem(at: remote) }
            let conduit = try Conduit(vaultURL: vault)
            let placeholder = vault.appendingPathComponent(".gitkeep")
            try "".write(to: placeholder, atomically: true, encoding: .utf8)
            _ = try conduit.commit(message: "Initial vault setup")
            try conduit.setRemote(try makeBareRemote(at: remote))

            // The bare remote is empty: there is no origin/<branch> for the
            // local branch to be set upstream to.
            let error = #expect(throws: VaultError.self) { _ = try conduit.pull() }
            guard case .gitInvocationFailed = error else {
                Issue.record("expected gitInvocationFailed, got \(String(describing: error))")
                return
            }
        }
    }
}
