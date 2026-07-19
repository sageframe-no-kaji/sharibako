import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// Tests for the welcome tour (ho-06.3 gate-fix round).
///
/// The Help-menu re-entry into `WorkshopModel+FirstRun.swift`'s wizard state
/// machine over an already-open vault: `presentWelcomeTour()`/
/// `dismissWelcomeTour()`, the `.tour`-mode navigation variants, and — the
/// load-bearing assertions — the hard guards that keep every mutating intent
/// a no-op while touring.
///
/// See `WorkshopModelFirstRunTests.swift` for the split rationale and
/// `FirstRunTestSupport` (`AppTestSupport.swift`) for shared fixtures.
/// `FirstRunTestSupport.openVaultModel(vault:home:)` is this file's own
/// addition — every other first-run fixture is `.noVault`.
@MainActor
@Suite("WorkshopModel+FirstRun Welcome Tour")
struct WorkshopModelFirstRunTourTests {
    // MARK: - Present / dismiss

    @Test("presentWelcomeTour flips mode to tour and resets the page state, only with an open vault")
    func presentTourOverOpenVault() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            try WorkshopTestSupport.withTempVault { vault in
                let model = FirstRunTestSupport.openVaultModel(vault: vault, home: home)
                guard case .open = model.vaultState else {
                    Issue.record("fixture should already be open")
                    return
                }
                // Stale state from a hypothetical earlier tour or first-run
                // attempt — presentWelcomeTour() must reset every field, not
                // just flip the mode.
                model.firstRun.page = .remote
                model.firstRun.keyMode = .existingKeyFound
                model.firstRun.remoteURLText = "git@host:leftover.git"

                model.presentWelcomeTour()

                #expect(model.firstRun.mode == .tour)
                #expect(model.firstRun.page == .prereq)
                #expect(model.firstRun.keyMode == .notChosen)
                #expect(model.firstRun.remoteURLText.isEmpty)
                #expect(model.firstRun.scanRoot == nil)
            }
        }
    }

    @Test("presentWelcomeTour is a no-op without an open vault")
    func presentTourNoOpWithoutVault() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            let model = FirstRunTestSupport.noVaultModel(home: home)

            model.presentWelcomeTour()

            #expect(model.firstRun.mode == .firstRun)
        }
    }

    @Test("dismissWelcomeTour clears tour mode and resets to the prereq page")
    func dismissTourClearsMode() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            try WorkshopTestSupport.withTempVault { vault in
                let model = FirstRunTestSupport.openVaultModel(vault: vault, home: home)
                model.presentWelcomeTour()
                model.firstRun.page = .remote

                model.dismissWelcomeTour()

                #expect(model.firstRun.mode == .firstRun)
                #expect(model.firstRun.page == .prereq)
            }
        }
    }

    // MARK: - Hard guards: tour never mutates

    @Test("generateFirstRunKey is a no-op in tour mode — the tour never generates a key")
    func generateNoOpInTourMode() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            try WorkshopTestSupport.withTempVault { vault in
                let model = FirstRunTestSupport.openVaultModel(vault: vault, home: home)
                model.presentWelcomeTour()
                let store = FakeKeychainStore()

                model.generateFirstRunKey(store: store)

                #expect(store.storedContents == nil)
                #expect(model.firstRun.keyMode == .notChosen)
                #expect(model.firstRun.pendingBackup == nil)
                #expect(model.firstRun.page == .prereq)
            }
        }
    }

    @Test("importFirstRunKey is a no-op in tour mode — the tour never imports a key")
    func importNoOpInTourMode() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            try WorkshopTestSupport.withTempVault { vault in
                try AppAgeKeyFixture.withEphemeralKey { fixture in
                    let model = FirstRunTestSupport.openVaultModel(vault: vault, home: home)
                    model.presentWelcomeTour()
                    let store = FakeKeychainStore()

                    model.importFirstRunKey(from: fixture.privateKeyURL, store: store)

                    #expect(store.storedContents == nil)
                    #expect(model.firstRun.keyMode == .notChosen)
                    #expect(model.firstRun.page == .prereq)
                }
            }
        }
    }

    @Test("completeFirstRun is a no-op in tour mode even against a .noVault state")
    func completeFirstRunNoOpInTourMode() async throws {
        try await WorkshopTestSupport.withTempDirectory { home in
            // Deliberately contrived: `presentWelcomeTour()` only ever
            // reaches `.tour` mode over an `.open` vault, so the existing
            // `.noVault` guard in `completeFirstRun()` would already catch
            // this combination on its own. Forcing `mode = .tour` onto a
            // `.noVault` model isolates the NEW guard and proves it, on its
            // own, refuses to create a vault or write config.yaml — not
            // merely "vaultState happened to block it too."
            let model = FirstRunTestSupport.noVaultModel(home: home)
            let scanRoot = home.appendingPathComponent("scan-root")
            try FileManager.default.createDirectory(at: scanRoot, withIntermediateDirectories: true)
            model.setFirstRunScanRootOverride(scanRoot)
            model.firstRun.mode = .tour

            await model.completeFirstRun()

            guard case .noVault = model.vaultState else {
                Issue.record("expected .noVault to be unchanged — completeFirstRun must not run in tour mode")
                return
            }
            #expect(model.firstRunCompleted == false)
            #expect(!FileManager.default.fileExists(atPath: model.configURL.path))
        }
    }

    @Test("completeFirstRun in tour mode over an already-open vault touches nothing")
    func completeFirstRunNoOpOverOpenVaultInTourMode() async throws {
        try await WorkshopTestSupport.withTempDirectory { home in
            try await WorkshopTestSupport.withTempVault { vault in
                let model = FirstRunTestSupport.openVaultModel(vault: vault, home: home)
                model.presentWelcomeTour()
                model.firstRun.scanRoot = vault

                await model.completeFirstRun()

                #expect(model.firstRunCompleted == false)
                #expect(!FileManager.default.fileExists(atPath: model.configURL.path))
            }
        }
    }

    // MARK: - Tour-mode navigation

    @Test("firstRunCanContinue never gates on the key or root pages while touring")
    func canContinueAlwaysTrueInTourMode() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            try WorkshopTestSupport.withTempVault { vault in
                let model = FirstRunTestSupport.openVaultModel(vault: vault, home: home)
                model.presentWelcomeTour()

                model.firstRun.page = .key
                #expect(model.firstRun.keyMode == .notChosen)
                #expect(model.firstRunCanContinue == true)

                model.firstRun.page = .root
                #expect(model.firstRun.scanRoot == nil)
                #expect(model.firstRunCanContinue == true)
            }
        }
    }

    @Test("advanceFromKeyPage always advances in tour mode, key found or not")
    func advanceFromKeyPageAlwaysAdvancesInTour() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            try WorkshopTestSupport.withTempVault { vault in
                let model = FirstRunTestSupport.openVaultModel(vault: vault, home: home)
                model.presentWelcomeTour()
                model.firstRun.page = .key

                model.advanceFirstRunPage()

                #expect(model.firstRun.page == .root)
            }
        }
    }

    @Test("advanceFromRoot always advances in tour mode without a scanRoot")
    func advanceFromRootAlwaysAdvancesInTour() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            try WorkshopTestSupport.withTempVault { vault in
                let model = FirstRunTestSupport.openVaultModel(vault: vault, home: home)
                model.presentWelcomeTour()
                model.firstRun.page = .root

                model.advanceFirstRunPage()

                #expect(model.firstRun.page == .remote)
            }
        }
    }

    @Test("goToPreviousFirstRunPage from root lands on key in tour mode (backup was never visited)")
    func goToPreviousFromRootInTourMode() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            try WorkshopTestSupport.withTempVault { vault in
                let model = FirstRunTestSupport.openVaultModel(vault: vault, home: home)
                model.presentWelcomeTour()
                model.firstRun.page = .root

                model.goToPreviousFirstRunPage()

                #expect(model.firstRun.page == .key)
            }
        }
    }

    // MARK: - The tour never probes the Keychain (gate-fix round, 2026-07-19)

    @Test("checkExistingKeychainKey is a no-op in tour mode — the tour never probes the Keychain")
    func keychainProbeNoOpInTourMode() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            try WorkshopTestSupport.withTempVault { vault in
                let model = FirstRunTestSupport.openVaultModel(vault: vault, home: home)
                model.presentWelcomeTour()
                model.firstRun.page = .key

                // A store that WOULD report a key: the guard means the
                // result never lands on keyMode.
                let store = FakeKeychainStore()
                store.existsResult = true
                model.checkExistingKeychainKey(store: store)
                #expect(model.firstRun.keyMode == .notChosen)

                // A store that WOULD throw: the guard means no error
                // surfaces either — the probe simply never runs.
                let failingStore = FakeKeychainStore()
                failingStore.existsError = AgeKeyAccessError.keychainLoadFailed(osStatus: -1)
                model.checkExistingKeychainKey(store: failingStore)
                #expect(model.firstRun.errorMessage == nil)
            }
        }
    }

    @Test("tourKeySourceDescription states the Keychain by default and the file path under a dev key")
    func tourKeySourceDescriptionStatesLiveTruth() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            try WorkshopTestSupport.withTempVault { vault in
                let keychainModel = FirstRunTestSupport.openVaultModel(vault: vault, home: home)
                #expect(keychainModel.tourKeySourceDescription.contains("Keychain"))

                let keyPath = home.appendingPathComponent("scratch-key.txt").path
                let fileKeyModel = FirstRunTestSupport.openVaultModel(
                    vault: vault,
                    home: home,
                    environmentExtra: ["SHARIBAKO_AGE_KEY": keyPath]
                )
                #expect(fileKeyModel.tourKeySourceDescription.contains(keyPath))
            }
        }
    }

    // MARK: - firstRunKeyPageOffersActions

    @Test("firstRunKeyPageOffersActions is false in tour mode regardless of keyMode")
    func keyPageOffersActionsFalseInTour() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            try WorkshopTestSupport.withTempVault { vault in
                let model = FirstRunTestSupport.openVaultModel(vault: vault, home: home)
                model.presentWelcomeTour()

                #expect(model.firstRunKeyPageOffersActions == false)

                model.firstRun.keyMode = .existingKeyFound
                #expect(model.firstRunKeyPageOffersActions == false)
            }
        }
    }

    @Test("firstRunKeyPageOffersActions is true in firstRun mode until a key is found")
    func keyPageOffersActionsTrueInFirstRun() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            let model = FirstRunTestSupport.noVaultModel(home: home)

            #expect(model.firstRunKeyPageOffersActions == true)

            model.firstRun.keyMode = .existingKeyFound
            #expect(model.firstRunKeyPageOffersActions == false)
        }
    }
}
