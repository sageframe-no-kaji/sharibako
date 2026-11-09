import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// ho-06.10 AT-04 tests: Remote… and Scan folders… — the vault's remote and
/// the folders searched for projects, edited from the Workshop.
///
/// Real temp vaults (git ones for the remote) and an injected temp `home`, so
/// `config.yaml` is the test's own; asserting model state and the files.
@MainActor
@Suite("WorkshopModel Vault Settings")
struct WorkshopModelVaultSettingsTests {
    // MARK: - Remote…

    @Test("Remote… opens on the current remote, refuses an empty or unsafe URL in the sheet, and saves")
    func setAndChangeRemote() async throws {
        try await withGitVaultAndBareRemote { vault, remote in
            let model = ProjectsTestSupport.model(vault: vault)
            await model.performLaunchScan()
            #expect(model.remoteSheetCurrent == remote.path)
            #expect(model.canRemoveRemote)

            model.openRemoteSheet()
            #expect(model.remoteSheet == .init(draft: remote.path, error: nil))
            model.remoteSheet?.draft = "  "
            model.saveRemote()
            #expect(model.remoteSheet?.error == "Enter the remote's URL, or use Remove to have none.")
            model.remoteSheet?.draft = "ext::sh -c touch% /tmp/pwned"
            model.saveRemote()
            #expect(model.remoteSheet?.error?.hasPrefix("Remote rejected:") == true)
            #expect(model.remoteDescription == .configured(url: remote.path))

            model.remoteSheet?.draft = "https://example.invalid/vault.git"
            model.saveRemote()
            #expect(model.remoteSheet == nil)
            #expect(model.remoteDescription == .configured(url: "https://example.invalid/vault.git"))
            #expect(model.remoteShortDescription != nil)
            #expect(
                model.statusMessage == "Remote set to https://example.invalid/vault.git. Sync backs the vault up there."
            )
        }
    }

    @Test("Remove unsets the remote and the footer says No remote")
    func removeRemote() async throws {
        try await withGitVaultAndBareRemote { vault, _ in
            let model = ProjectsTestSupport.model(vault: vault)
            await model.performLaunchScan()
            model.removeRemote()  // no sheet open: nothing happens
            #expect(model.canRemoveRemote)

            model.openRemoteSheet()
            model.removeRemote()
            #expect(model.remoteSheet == nil)
            #expect(model.remoteDescription == WorkshopModel.RemoteDescription.none)
            #expect(model.remoteSheetCurrent == "No remote")
            #expect(model.remoteShortDescription == "No remote")
            #expect(!model.canRemoveRemote)
            #expect(model.statusMessage == "Remote removed. Sync now keeps the vault's history on this Mac only.")
            let gitRemote = try Conduit(vaultURL: vault).remoteURL()
            #expect(gitRemote == nil)

            model.openRemoteSheet()
            #expect(model.remoteSheet?.draft.isEmpty == true)
            model.dismissRemoteSheet()
            #expect(model.remoteSheet == nil)
        }
    }

    @Test("a vault with no git repository keeps the sheet open with git's refusal")
    func remoteOnNonGitVault() throws {
        try WorkshopTestSupport.withTempVault { vault in
            let model = ProjectsTestSupport.model(vault: vault)
            model.openRemoteSheet()
            model.remoteSheet?.draft = "https://example.invalid/vault.git"
            model.saveRemote()
            #expect(model.remoteSheet?.error?.hasPrefix("Git error:") == true)
        }
    }

    @Test("Remote… does nothing before a vault exists")
    func remoteWithoutVault() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            let model = FirstRunTestSupport.noVaultModel(home: home)
            model.openRemoteSheet()
            #expect(model.remoteSheet == nil)
            model.openScanFolders()
            #expect(!model.isScanFoldersSheetPresented)
        }
    }

    // MARK: - Scan folders…

    @Test("Scan folders adds and removes folders in config.yaml; closing rescans the new list")
    func addRemoveAndRescan() async throws {
        try await WorkshopTestSupport.withTempDirectory { home in
            try await WorkshopTestSupport.withTempVault { vault in
                let root = try ProjectsTestSupport.makeRoot(near: vault)
                defer { try? FileManager.default.removeItem(at: root) }
                try ProjectsTestSupport.writeEnv("API_KEY=sk\n", in: root.appendingPathComponent("acme"))
                let model = FirstRunTestSupport.openVaultModel(vault: vault, home: home)

                model.openScanFolders()
                #expect(model.isScanFoldersSheetPresented)
                #expect(model.scanRoots.isEmpty)
                #expect(WorkshopModel.noScanFoldersText.hasPrefix("No folders are scanned yet."))

                model.addScanFolder(root)
                #expect(WorkshopConfig.loadScanRoots(configURL: model.configURL).map(\.path) == [root.path])
                #expect(model.scanRoots.map(\.path) == [root.path])
                #expect(model.statusMessage?.hasPrefix("Added ") == true)
                model.addScanFolder(root)
                #expect(model.scanRoots.count == 1)
                #expect(model.statusMessage?.hasSuffix("is already scanned.") == true)

                await model.closeScanFolders()
                #expect(!model.isScanFoldersSheetPresented)
                #expect(model.candidates.map(\.lastPathComponent) == ["acme"])
                #expect(model.statusMessage == WorkshopModel.rescanSummary(toProtect: 1, alreadyProtected: 0))

                model.openScanFolders()
                #expect(model.scanRoots.map(\.path) == [root.path])
                model.removeScanFolder(root)
                #expect(model.scanRoots.isEmpty)
                #expect(WorkshopConfig.loadScanRoots(configURL: model.configURL).isEmpty)
                #expect(model.statusMessage?.hasPrefix("Removed ") == true)
                await model.closeScanFolders()
                #expect(model.candidates.isEmpty)
                #expect(model.scanReport?.markers.isEmpty == true)
                #expect(model.statusMessage == "No folders are scanned — add one with Scan folders… to find projects.")

                await model.closeScanFolders()  // already closed: nothing happens
                #expect(model.statusMessage == "No folders are scanned — add one with Scan folders… to find projects.")
            }
        }
    }

    @Test("a config that cannot be written reports the failure and keeps the list")
    func unwritableConfig() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            try WorkshopTestSupport.withTempVault { vault in
                // A file where the config's directory should be makes every write fail.
                let blocker = home.appendingPathComponent("Library")
                try "not a directory".write(to: blocker, atomically: true, encoding: .utf8)
                let model = FirstRunTestSupport.openVaultModel(vault: vault, home: home)
                model.addScanFolder(vault)
                #expect(model.errorMessage != nil)
                #expect(model.scanRoots.isEmpty)
            }
        }
    }
}
