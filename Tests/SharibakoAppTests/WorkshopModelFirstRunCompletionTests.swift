import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// Tests for the first-run wizard's page navigation and `completeFirstRun()`
/// (ho-06.3), declared in `WorkshopModel+FirstRun.swift`.
///
/// See `WorkshopModelFirstRunTests.swift` for the split rationale and
/// `FirstRunTestSupport` (`AppTestSupport.swift`) for shared fixtures.
/// `completeFirstRun()`'s git-identity probe isolates `HOME` via
/// `WorkshopModel/processEnvironment` so nothing here reads the real
/// developer machine's own git identity (Do Not §4).
@MainActor
@Suite("WorkshopModel+FirstRun Completion")
struct WorkshopModelFirstRunCompletionTests {
    // MARK: - Navigation

    @Test("firstRunCanContinue mirrors each page's own advance guard")
    func canContinueMirrorsGuards() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            let model = FirstRunTestSupport.noVaultModel(home: home)

            model.firstRun.page = .prereq
            #expect(model.firstRunCanContinue == false)
            model.firstRun.prerequisitesOK = true
            #expect(model.firstRunCanContinue == true)

            model.firstRun.page = .key
            #expect(model.firstRunCanContinue == false)
            model.firstRun.keyMode = .existingKeyFound
            #expect(model.firstRunCanContinue == true)

            model.firstRun.page = .backup
            #expect(model.firstRunCanContinue == false)
            model.firstRun.backupVerified = true
            #expect(model.firstRunCanContinue == true)

            model.firstRun.page = .root
            #expect(model.firstRunCanContinue == false)
            model.firstRun.scanRoot = home
            #expect(model.firstRunCanContinue == true)

            model.firstRun.page = .remote
            #expect(model.firstRunCanContinue == true)

            model.firstRun.page = .finish
            #expect(model.firstRunCanContinue == false)
        }
    }

    @Test("goToPreviousFirstRunPage steps back, mirroring whichever forward path ran")
    func goToPreviousPage() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            let model = FirstRunTestSupport.noVaultModel(home: home)

            model.firstRun.page = .prereq
            model.goToPreviousFirstRunPage()
            #expect(model.firstRun.page == .prereq)

            model.firstRun.page = .key
            model.goToPreviousFirstRunPage()
            #expect(model.firstRun.page == .prereq)

            model.firstRun.page = .backup
            model.goToPreviousFirstRunPage()
            #expect(model.firstRun.page == .key)

            // Generate path: root's previous page is backup.
            model.firstRun.keyMode = .generated
            model.firstRun.page = .root
            model.goToPreviousFirstRunPage()
            #expect(model.firstRun.page == .backup)

            // Import path: root's previous page is key (backup was skipped).
            model.firstRun.keyMode = .imported
            model.firstRun.page = .root
            model.goToPreviousFirstRunPage()
            #expect(model.firstRun.page == .key)

            model.firstRun.page = .remote
            model.goToPreviousFirstRunPage()
            #expect(model.firstRun.page == .root)

            model.firstRun.page = .finish
            model.goToPreviousFirstRunPage()
            #expect(model.firstRun.page == .remote)
        }
    }

    // MARK: - completeFirstRun

    @Test("completeFirstRun creates the vault, git repo, and falls back to a local identity")
    func completeFirstRunCreatesVaultWithIdentityFallback() async throws {
        try await WorkshopTestSupport.withTempDirectory { home in
            let scanRoot = home.appendingPathComponent("scan-root")
            try FileManager.default.createDirectory(at: scanRoot, withIntermediateDirectories: true)
            // Isolate HOME for the git-identity probe so this test never reads
            // the real developer machine's own global git identity — an empty
            // fake HOME has no ~/.gitconfig, so the fallback must fire.
            let fakeGitHome = home.appendingPathComponent("fake-git-home")
            try FileManager.default.createDirectory(
                at: fakeGitHome, withIntermediateDirectories: true)
            let model = FirstRunTestSupport.noVaultModel(
                home: home, environmentExtra: ["HOME": fakeGitHome.path])
            model.setFirstRunScanRootOverride(scanRoot)

            await model.completeFirstRun()

            let expectedVaultURL = home.appendingPathComponent("vault")
            guard case .open(let vaultURL) = model.vaultState else {
                Issue.record("expected .open, got \(model.vaultState)")
                return
            }
            #expect(
                FirstRunTestSupport.normalizedPath(vaultURL)
                    == FirstRunTestSupport.normalizedPath(expectedVaultURL))
            #expect(WorkshopConfig.isVaultDirectory(vaultURL))
            #expect(
                FileManager.default.fileExists(
                    atPath: vaultURL.appendingPathComponent(".git").path))
            #expect(model.firstRunCompleted == true)
            #expect(model.statusMessage?.hasPrefix("Created vault") == true)
            #expect(
                model.scanRoots.contains {
                    FirstRunTestSupport.normalizedPath($0) == FirstRunTestSupport.normalizedPath(scanRoot)
                })

            let result = try Shell.run(
                Shell.findExecutable("git"),
                ["-C", vaultURL.path, "config", "user.email"],
                environmentOverrides: ["HOME": fakeGitHome.path]
            )
            #expect(
                result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "sharibako@localhost")
        }
    }

    @Test("completeFirstRun surfaces a rejected remote inline without aborting vault creation")
    func completeFirstRunRejectedRemoteDoesNotAbort() async throws {
        try await WorkshopTestSupport.withTempDirectory { home in
            let scanRoot = home.appendingPathComponent("scan-root")
            try FileManager.default.createDirectory(at: scanRoot, withIntermediateDirectories: true)
            let model = FirstRunTestSupport.noVaultModel(home: home)
            model.setFirstRunScanRootOverride(scanRoot)
            model.setFirstRunRemoteURL("ext::sh -c 'echo pwned'")

            await model.completeFirstRun()

            guard case .open = model.vaultState else {
                Issue.record("expected .open even with a rejected remote")
                return
            }
            #expect(model.firstRun.remoteURLError != nil)
            #expect(model.firstRunCompleted == true)
        }
    }

    @Test("completeFirstRun sets the given remote when it is accepted")
    func completeFirstRunAcceptsValidRemote() async throws {
        try await WorkshopTestSupport.withTempDirectory { home in
            let scanRoot = home.appendingPathComponent("scan-root")
            try FileManager.default.createDirectory(at: scanRoot, withIntermediateDirectories: true)
            let model = FirstRunTestSupport.noVaultModel(home: home)
            model.setFirstRunScanRootOverride(scanRoot)
            model.setFirstRunRemoteURL("/tmp/nonexistent-remote.git")

            await model.completeFirstRun()

            guard case .open(let vaultURL) = model.vaultState else {
                Issue.record("expected .open")
                return
            }
            #expect(model.firstRun.remoteURLError == nil)
            let conduit = try Conduit(vaultURL: vaultURL)
            #expect(try conduit.remoteURL() == "/tmp/nonexistent-remote.git")
        }
    }

    @Test("completeFirstRun is a no-op without a resolved scan root")
    func completeFirstRunRequiresScanRoot() async throws {
        try await WorkshopTestSupport.withTempDirectory { home in
            let model = FirstRunTestSupport.noVaultModel(home: home)

            await model.completeFirstRun()

            guard case .noVault = model.vaultState else {
                Issue.record("expected .noVault to be unchanged")
                return
            }
        }
    }

    @Test("completeFirstRun is a no-op when the vault is already open")
    func completeFirstRunNoOpWhenAlreadyOpen() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            guard case .open = model.vaultState else {
                Issue.record("fixture should already be open")
                return
            }
            model.setFirstRunScanRootOverride(vault)

            await model.completeFirstRun()

            #expect(model.firstRunCompleted == false)
        }
    }
}
