import Foundation
import Testing

@testable import SharibakoCore

/// Tests for the `Conduit` type's remote git operations.
///
/// Every test that needs a real remote uses the `withEphemeralBareRemote` fixture,
/// which spins up a `git init --bare` directory in a temp location and two vault
/// directories that clone from it — no network required.
@Suite("Conduit Remote")
struct ConduitRemoteTests {
    // MARK: - No-remote guard

    @Test("push returns noRemote when no origin is configured")
    func pushReturnsNoRemoteWhenAbsent() throws {
        try VaultTestSupport.withEphemeralGitVault { vault in
            let conduit = try Conduit(vaultURL: vault)
            let result = try conduit.push()
            #expect(result == .noRemote)
        }
    }

    @Test("pull returns noRemote when no origin is configured")
    func pullReturnsNoRemoteWhenAbsent() throws {
        try VaultTestSupport.withEphemeralGitVault { vault in
            let conduit = try Conduit(vaultURL: vault)
            let result = try conduit.pull()
            #expect(result == .noRemote)
        }
    }

    // MARK: - Up-to-date

    @Test("push returns upToDate when remote already has the commits")
    func pushReturnsUpToDateWhenSynced() throws {
        try VaultTestSupport.withEphemeralBareRemote { vaultA, _, _ in
            // vaultA already pushed the initial commit in the fixture setup.
            let conduitA = try Conduit(vaultURL: vaultA)
            let result = try conduitA.push()
            #expect(result == .upToDate)
        }
    }

    @Test("pull returns upToDate when local is already current")
    func pullReturnsUpToDateWhenSynced() throws {
        try VaultTestSupport.withEphemeralBareRemote { _, vaultB, _ in
            // vaultB was cloned from the same state vaultA pushed — nothing new to pull.
            let conduitB = try Conduit(vaultURL: vaultB)
            let result = try conduitB.pull()
            #expect(result == .upToDate)
        }
    }

    // MARK: - Round-trip

    @Test("bare-remote round trip: secret added in A is readable in B after push/pull")
    func bareRemoteRoundTrip() throws {
        try VaultTestSupport.withEphemeralBareRemote { vaultA, vaultB, fixture in
            // Add a scope and secret in vaultA.
            try VaultTestSupport.writeScope("dev", type: .other, in: vaultA)
            let coreA = try VaultCore(vaultURL: vaultA, ageKeyURL: fixture.privateKeyURL)
            try coreA.addSecret("DATABASE_URL", value: "postgres://local/mydb", inScope: "dev")

            let conduitA = try Conduit(vaultURL: vaultA)
            let commitResult = try conduitA.commit(message: "add DATABASE_URL")
            guard case .success = commitResult else {
                Issue.record("Expected commit success, got \(commitResult)")
                return
            }

            let pushResult = try conduitA.push()
            guard case .success(let pushed) = pushResult else {
                Issue.record("Expected push success, got \(pushResult)")
                return
            }
            #expect(pushed >= 1)

            // Pull in vaultB.
            let conduitB = try Conduit(vaultURL: vaultB)
            let pullResult = try conduitB.pull()
            guard case .success(let pulled) = pullResult else {
                Issue.record("Expected pull success, got \(pullResult)")
                return
            }
            #expect(pulled >= 1)

            // Decrypt the secret in vaultB — should match what was set in vaultA.
            let coreB = try VaultCore(vaultURL: vaultB, ageKeyURL: fixture.privateKeyURL)
            let value = try coreB.getValue("DATABASE_URL", inScope: "dev")
            #expect(value == "postgres://local/mydb")
        }
    }

    // MARK: - Push rejected

    @Test("push rejected when remote has diverged (non-fast-forward)")
    func pushRejectedWhenNonFastForward() throws {
        try VaultTestSupport.withEphemeralBareRemote { vaultA, vaultB, _ in
            // Create the scopes directory in vaultA so we have somewhere to write files.
            let scopesA = vaultA.appendingPathComponent("scopes")
            try FileManager.default.createDirectory(at: scopesA, withIntermediateDirectories: true)

            // A commits a file and pushes first.
            let fileA = scopesA.appendingPathComponent("fromA.txt")
            try "from A".write(to: fileA, atomically: true, encoding: .utf8)
            let conduitA = try Conduit(vaultURL: vaultA)
            _ = try conduitA.commit(message: "commit from A")
            let pushA = try conduitA.push()
            guard case .success = pushA else {
                Issue.record("Expected A push success, got \(pushA)")
                return
            }

            // B makes a conflicting commit (on a different file) without pulling.
            // vaultB was cloned before A's new commit, so it already has scopes/.
            let scopesB = vaultB.appendingPathComponent("scopes")
            try FileManager.default.createDirectory(at: scopesB, withIntermediateDirectories: true)
            let fileB = scopesB.appendingPathComponent("fromB.txt")
            try "from B".write(to: fileB, atomically: true, encoding: .utf8)
            let conduitB = try Conduit(vaultURL: vaultB)
            _ = try conduitB.commit(message: "commit from B")
            let pushB = try conduitB.push()
            guard case .rejected(let reason) = pushB else {
                Issue.record("Expected push rejection, got \(pushB)")
                return
            }
            // Reason should mention the rejection.
            #expect(!reason.isEmpty)
        }
    }

    // MARK: - Auto-aborted conflict

    @Test("pull aborts merge on conflict and leaves vault clean")
    func pullAbortsConflictAndLeavesCleanState() throws {
        try VaultTestSupport.withEphemeralBareRemote { vaultA, vaultB, fixture in
            let scopeID = "dev"

            // Step 1: A sets up the scope, adds the secret, pushes.
            try VaultTestSupport.writeScope(scopeID, type: .other, in: vaultA)
            let coreA = try VaultCore(vaultURL: vaultA, ageKeyURL: fixture.privateKeyURL)
            try coreA.addSecret("OPENAI_API_KEY", value: "sk-initial", inScope: scopeID)
            let conduitA = try Conduit(vaultURL: vaultA)
            _ = try conduitA.commit(message: "add OPENAI_API_KEY initial")
            _ = try conduitA.push()

            // Step 2: B pulls — gets the scope and initial secret.
            // (No local untracked files — the pull can proceed cleanly.)
            let conduitB = try Conduit(vaultURL: vaultB)
            let pullInitial = try conduitB.pull()
            guard case .success = pullInitial else {
                Issue.record("Expected initial pull success, got \(pullInitial)")
                return
            }

            // Step 3: B rotates the key to "sk-bbbb", commits (does NOT push yet).
            let coreBAfter = try VaultCore(vaultURL: vaultB, ageKeyURL: fixture.privateKeyURL)
            try coreBAfter.rotate("OPENAI_API_KEY", inScope: scopeID, newValue: "sk-bbbb")
            _ = try conduitB.commit(message: "rotate OPENAI_API_KEY from B")

            // Step 4: A rotates the same key to "sk-aaaa-v2", commits, pushes.
            // Now A's branch is ahead of B's last-pulled state with a conflicting change.
            try coreA.rotate("OPENAI_API_KEY", inScope: scopeID, newValue: "sk-aaaa-v2")
            _ = try conduitA.commit(message: "rotate OPENAI_API_KEY from A v2")
            _ = try conduitA.push()

            // Step 5: B tries to pull — conflict on OPENAI_API_KEY.age.
            let conflictResult = try conduitB.pull()
            guard case .abortedConflict(let conflicts) = conflictResult else {
                Issue.record("Expected abortedConflict, got \(conflictResult)")
                return
            }

            // Verify conflict list is non-empty and names the correct file.
            #expect(!conflicts.isEmpty)
            let keyFile =
                vaultB
                .appendingPathComponent("scopes/\(scopeID)/OPENAI_API_KEY.age")
            let hasConflict = conflicts.contains { $0.path == keyFile }
            #expect(hasConflict, "Expected OPENAI_API_KEY.age in conflicts, got \(conflicts)")

            // Verify SHAs are non-empty and differ.
            for conflict in conflicts {
                #expect(!conflict.localSHA.isEmpty)
                #expect(!conflict.remoteSHA.isEmpty)
                #expect(conflict.localSHA != conflict.remoteSHA)
            }

            // Vault must be clean after auto-abort.
            let status = try conduitB.status()
            #expect(!status.dirty, "Expected clean vault after merge abort, dirty=\(status.dirty)")
        }
    }

    @Test("ConflictedFile SHAs are real git objects retrievable with cat-file -p")
    func conflictSHAsAreRealObjects() throws {
        try VaultTestSupport.withEphemeralBareRemote { vaultA, vaultB, fixture in
            let scopeID = "dev"

            // Step 1: A sets up the scope, adds a secret, pushes.
            try VaultTestSupport.writeScope(scopeID, type: .other, in: vaultA)
            let coreA = try VaultCore(vaultURL: vaultA, ageKeyURL: fixture.privateKeyURL)
            try coreA.addSecret("SECRET_KEY", value: "value-A", inScope: scopeID)
            let conduitA = try Conduit(vaultURL: vaultA)
            _ = try conduitA.commit(message: "add SECRET_KEY from A")
            _ = try conduitA.push()

            // Step 2: B pulls — gets the scope and initial secret.
            let conduitB = try Conduit(vaultURL: vaultB)
            let pullInitial = try conduitB.pull()
            guard case .success = pullInitial else {
                Issue.record("Expected initial pull success, got \(pullInitial)")
                return
            }

            // Step 3: B rotates, commits.
            let coreBAfter = try VaultCore(vaultURL: vaultB, ageKeyURL: fixture.privateKeyURL)
            try coreBAfter.rotate("SECRET_KEY", inScope: scopeID, newValue: "value-B")
            _ = try conduitB.commit(message: "rotate SECRET_KEY from B")

            // Step 4: A rotates to a different value, commits, pushes.
            try coreA.rotate("SECRET_KEY", inScope: scopeID, newValue: "value-A-v2")
            _ = try conduitA.commit(message: "rotate SECRET_KEY from A v2")
            _ = try conduitA.push()

            // Step 5: B pulls — should conflict.
            let conflictResult = try conduitB.pull()
            guard case .abortedConflict(let conflicts) = conflictResult else {
                Issue.record("Expected abortedConflict, got \(conflictResult)")
                return
            }

            guard let conflict = conflicts.first else {
                Issue.record("Expected at least one ConflictedFile")
                return
            }

            // Verify each SHA can be retrieved from vaultB's object database.
            let git = try Shell.findExecutable("git")
            let localCheck = try Shell.run(
                git,
                ["cat-file", "-p", conflict.localSHA],
                workingDirectory: vaultB
            )
            #expect(localCheck.exitCode == 0, "localSHA \(conflict.localSHA) not a valid object")

            let remoteCheck = try Shell.run(
                git,
                ["cat-file", "-p", conflict.remoteSHA],
                workingDirectory: vaultB
            )
            #expect(remoteCheck.exitCode == 0, "remoteSHA \(conflict.remoteSHA) not a valid object")
        }
    }
}
