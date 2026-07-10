import Foundation
import Testing

@testable import SharibakoCore

/// Tests for `Conduit.log(fileURL:)` (ho-05 AT-02, Decision 6).
///
/// Each test builds an ephemeral git vault, writes and commits a scope secret
/// file one or more times, then asserts the history returned by `log`.
@Suite("Conduit Log")
struct ConduitLogTests {
    // MARK: - Tracked file with one commit

    @Test("log returns one CommitInfo for a file committed once")
    func logSingleCommit() throws {
        try VaultTestSupport.withEphemeralGitVault { vault in
            let conduit = try Conduit(vaultURL: vault)
            try VaultTestSupport.writeScope("scope1", type: .other, in: vault)
            let fileURL = try VaultLayout.scopeYAMLURL("scope1", in: vault)

            _ = try conduit.commit(message: "add scope1")

            let history = try conduit.log(fileURL: fileURL)
            #expect(history.count == 1)
            #expect(history[0].subject == "add scope1")
            // SHA is seven hex chars
            #expect(history[0].shortSHA.count == 7)
            #expect(history[0].shortSHA.allSatisfy { $0.isHexDigit })
            // Date is YYYY-MM-DD
            #expect(history[0].date.count == 10)
            #expect(history[0].date.contains("-"))
        }
    }

    // MARK: - Tracked file with two commits (newest-first)

    @Test("log returns two CommitInfos newest-first for two commits")
    func logTwoCommitsNewestFirst() throws {
        try VaultTestSupport.withEphemeralGitVault { vault in
            let conduit = try Conduit(vaultURL: vault)
            try VaultTestSupport.writeScope("scope2", type: .other, in: vault)
            let fileURL = try VaultLayout.scopeYAMLURL("scope2", in: vault)

            _ = try conduit.commit(message: "first write")

            // Modify the file and commit again.
            try VaultTestSupport.writeScope("scope2", type: .service, in: vault)
            _ = try conduit.commit(message: "second write")

            let history = try conduit.log(fileURL: fileURL)
            #expect(history.count == 2)
            // Newest commit is listed first.
            #expect(history[0].subject == "second write")
            #expect(history[1].subject == "first write")
        }
    }

    // MARK: - Untracked file returns []

    @Test("log returns [] for a file that has never been committed")
    func logUntrackedFileReturnsEmpty() throws {
        try VaultTestSupport.withEphemeralGitVault { vault in
            let conduit = try Conduit(vaultURL: vault)

            // Write a file and commit it so the branch has at least one commit;
            // otherwise git exits 128 ("no commits yet") on a completely empty
            // repo and the "untracked" path is unreachable.
            try VaultTestSupport.writeScope("committed", type: .other, in: vault)
            let committedURL = try VaultLayout.scopeYAMLURL("committed", in: vault)
            _ = try conduit.commit(message: "initial commit")

            // Now write a *different*, uncommitted file — this is the untracked case.
            try VaultTestSupport.writeScope("scope3", type: .other, in: vault)
            let fileURL = try VaultLayout.scopeYAMLURL("scope3", in: vault)
            _ = committedURL  // silence unused warning

            // Deliberately do NOT commit scope3 — git log exits 0 with empty output.
            let history = try conduit.log(fileURL: fileURL)
            #expect(history.isEmpty)
        }
    }

    // MARK: - File not in vault (relative path edge case)

    @Test("log returns [] for a nonexistent path inside the vault (not committed)")
    func logAbsentFileReturnsEmpty() throws {
        try VaultTestSupport.withEphemeralGitVault { vault in
            let conduit = try Conduit(vaultURL: vault)

            // Need at least one commit on the branch so git log can run without
            // failing with "does not have any commits yet" (exit 128).
            try VaultTestSupport.writeScope("seed", type: .other, in: vault)
            _ = try conduit.commit(message: "seed commit")

            // A path that has never existed; git log exits 0 with empty output.
            let fileURL = vault.appendingPathComponent("scopes/ghost/GHOST.age")
            let history = try conduit.log(fileURL: fileURL)
            #expect(history.isEmpty)
        }
    }

    // MARK: - CommitInfo fields

    @Test("CommitInfo is Equatable")
    func commitInfoEquatable() {
        let first = CommitInfo(shortSHA: "abc1234", date: "2026-07-10", subject: "initial")
        let same = CommitInfo(shortSHA: "abc1234", date: "2026-07-10", subject: "initial")
        let different = CommitInfo(shortSHA: "def5678", date: "2026-07-10", subject: "initial")
        #expect(first == same)
        #expect(first != different)
    }

    @Test("CommitInfo initializer round-trips its fields")
    func commitInfoFields() {
        let info = CommitInfo(shortSHA: "aabbccd", date: "2026-01-15", subject: "rotate SECRET")
        #expect(info.shortSHA == "aabbccd")
        #expect(info.date == "2026-01-15")
        #expect(info.subject == "rotate SECRET")
    }
}
