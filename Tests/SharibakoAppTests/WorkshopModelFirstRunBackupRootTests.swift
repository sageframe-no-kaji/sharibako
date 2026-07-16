import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// Tests for the first-run wizard's backup, root, and remote pages
/// (ho-06.3), declared in `WorkshopModel+FirstRun.swift`.
///
/// See `WorkshopModelFirstRunTests.swift` for the split rationale and
/// `FirstRunTestSupport` (`AppTestSupport.swift`) for shared fixtures.
@MainActor
@Suite("WorkshopModel+FirstRun Backup/Root")
struct WorkshopModelFirstRunBackupRootTests {
    // MARK: - Backup page

    @Test("verifyFirstRunBackup passes only when the saved file matches the pending identity")
    func verifyBackupMatch() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            let model = FirstRunTestSupport.noVaultModel(home: home)
            model.firstRun.pendingBackup = WorkshopModel.FirstRunPendingBackup(
                identity: "AGE-SECRET-KEY-1FAKE\n", recipient: "age1fake")
            let saved = home.appendingPathComponent("backup.txt")
            try "AGE-SECRET-KEY-1FAKE\n".write(to: saved, atomically: true, encoding: .utf8)

            model.verifyFirstRunBackup(at: saved)

            #expect(model.firstRun.backupVerified == true)
        }
    }

    @Test("verifyFirstRunBackup fails when the saved file does not match")
    func verifyBackupMismatch() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            let model = FirstRunTestSupport.noVaultModel(home: home)
            model.firstRun.pendingBackup = WorkshopModel.FirstRunPendingBackup(
                identity: "AGE-SECRET-KEY-1FAKE\n", recipient: "age1fake")
            let saved = home.appendingPathComponent("backup.txt")
            try "something else entirely\n".write(to: saved, atomically: true, encoding: .utf8)

            model.verifyFirstRunBackup(at: saved)

            #expect(model.firstRun.backupVerified == false)
        }
    }

    @Test("verifyFirstRunBackup fails when no backup is pending or the file is missing")
    func verifyBackupNoPendingOrMissingFile() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            let model = FirstRunTestSupport.noVaultModel(home: home)
            let missing = home.appendingPathComponent("nope.txt")

            model.verifyFirstRunBackup(at: missing)
            #expect(model.firstRun.backupVerified == false)

            model.firstRun.pendingBackup = WorkshopModel.FirstRunPendingBackup(
                identity: "AGE-SECRET-KEY-1FAKE\n", recipient: "age1fake")
            model.verifyFirstRunBackup(at: missing)
            #expect(model.firstRun.backupVerified == false)
        }
    }

    @Test("advanceFromBackup requires verification, then clears the in-memory identity")
    func advanceFromBackupClearsIdentity() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            let model = FirstRunTestSupport.noVaultModel(home: home)
            model.firstRun.page = .backup
            model.firstRun.pendingBackup = WorkshopModel.FirstRunPendingBackup(
                identity: "AGE-SECRET-KEY-1FAKE\n", recipient: "age1fake")

            model.advanceFirstRunPage()
            #expect(model.firstRun.page == .backup)  // not verified yet

            model.firstRun.backupVerified = true
            model.advanceFromBackup()

            #expect(model.firstRun.page == .root)
            #expect(model.firstRun.pendingBackup == nil)
            #expect(model.firstRun.backupVerified == false)
        }
    }

    // MARK: - Root page

    @Test("suggestFirstRunScanRoot picks the sole existing candidate")
    func suggestSingleCandidate() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent("Projects"), withIntermediateDirectories: true)
            let model = FirstRunTestSupport.noVaultModel(home: home)

            model.suggestFirstRunScanRoot(home: home)

            #expect(
                model.firstRun.scanRoot.map(FirstRunTestSupport.normalizedPath)
                    == FirstRunTestSupport.normalizedPath(home.appendingPathComponent("Projects")))
        }
    }

    @Test("suggestFirstRunScanRoot returns nil when no candidate exists")
    func suggestNoCandidates() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            let model = FirstRunTestSupport.noVaultModel(home: home)

            model.suggestFirstRunScanRoot(home: home)

            #expect(model.firstRun.scanRoot == nil)
        }
    }

    @Test("suggestFirstRunScanRoot ties go to the earlier-preference candidate")
    func suggestTieBreaksToPreferenceOrder() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            // "Projects" precedes "Developer" in firstRunRootCandidates; both
            // exist with zero git repos — Projects must win the tie.
            for name in ["Developer", "Projects"] {
                try FileManager.default.createDirectory(
                    at: home.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            let model = FirstRunTestSupport.noVaultModel(home: home)

            model.suggestFirstRunScanRoot(home: home)

            #expect(
                model.firstRun.scanRoot.map(FirstRunTestSupport.normalizedPath)
                    == FirstRunTestSupport.normalizedPath(home.appendingPathComponent("Projects")))
        }
    }

    @Test("suggestFirstRunScanRoot's git-repo count overrides preference order")
    func suggestGitCountOverridesOrder() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            // "Projects" precedes "Developer" in preference order, but
            // "Developer" holds a git repo and "Projects" holds none — the
            // repo count must win over list order.
            let projects = home.appendingPathComponent("Projects")
            let developer = home.appendingPathComponent("Developer")
            try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: developer, withIntermediateDirectories: true)
            let repo = developer.appendingPathComponent("some-repo")
            try FileManager.default.createDirectory(
                at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
            let model = FirstRunTestSupport.noVaultModel(home: home)

            model.suggestFirstRunScanRoot(home: home)

            #expect(
                model.firstRun.scanRoot.map(FirstRunTestSupport.normalizedPath)
                    == FirstRunTestSupport.normalizedPath(developer))
        }
    }

    @Test("setFirstRunScanRootOverride accepts any folder-picker choice")
    func setScanRootOverride() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            let model = FirstRunTestSupport.noVaultModel(home: home)
            let chosen = home.appendingPathComponent("Somewhere")

            model.setFirstRunScanRootOverride(chosen)

            #expect(model.firstRun.scanRoot == chosen)
        }
    }

    @Test("advanceFromRoot requires a resolved scan root")
    func advanceFromRootGuards() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            let model = FirstRunTestSupport.noVaultModel(home: home)
            model.firstRun.page = .root

            model.advanceFirstRunPage()
            #expect(model.firstRun.page == .root)

            model.setFirstRunScanRootOverride(home.appendingPathComponent("chosen"))
            model.advanceFirstRunPage()
            #expect(model.firstRun.page == .remote)
        }
    }

    // MARK: - Remote page

    @Test("setFirstRunRemoteURL records the text and clears any prior rejection")
    func setRemoteURLClearsError() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            let model = FirstRunTestSupport.noVaultModel(home: home)
            model.firstRun.remoteURLError = "stale error"

            model.setFirstRunRemoteURL("git@example.com:repo.git")

            #expect(model.firstRun.remoteURLText == "git@example.com:repo.git")
            #expect(model.firstRun.remoteURLError == nil)
        }
    }

    @Test("advanceFromRemote always advances — the field is optional")
    func advanceFromRemoteAlwaysAdvances() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            let model = FirstRunTestSupport.noVaultModel(home: home)
            model.firstRun.page = .remote

            model.advanceFirstRunPage()

            #expect(model.firstRun.page == .finish)
        }
    }
}
