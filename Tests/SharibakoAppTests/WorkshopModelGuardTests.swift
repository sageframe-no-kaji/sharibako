import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// The two guards every Workshop intent opens with, swept across the surface.
///
/// *Is a vault actually open* and *is another action already in flight*. Both
/// are silent early returns by design — a menu item or panel button that fires
/// in the wrong state must do nothing rather than crash the window or start a
/// second write.
///
/// Swept rather than tested one-by-one because the guarantee is a property of
/// the surface, not of any single verb: a new intent that forgets either guard
/// should fail here. Nothing in this file reaches a vault, an age key, or the
/// Keychain — every call returns before it would.
@MainActor
@Suite("WorkshopModel guards")
struct WorkshopModelGuardTests {
    /// A model whose configured vault path does not exist, so `vaultState` is
    /// `.noVault` and every vault-bound intent must bail at its first guard.
    private func noVaultModel() -> WorkshopModel {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharibako-guard-\(UUID().uuidString)")
        return FirstRunTestSupport.noVaultModel(home: home)
    }

    private func openModel(vault: URL) -> WorkshopModel {
        WorkshopModel(
            environment: ["SHARIBAKO_VAULT": vault.path],
            home: URL(fileURLWithPath: "/Users/nobody")
        )
    }

    // MARK: - No vault open

    @Test("every mutation intent is a no-op while no vault is open")
    func mutationsNoOpWithoutVault() {
        let model = noVaultModel()

        model.addScope(id: "alpha", type: .other, displayName: "Alpha")
        model.addSecret(key: "DB", value: "v", notes: nil, inScope: "alpha")
        model.addSharedEntry(id: "SHARED", value: "v", notes: nil)
        model.editValue(key: "DB", inScope: "alpha", newValue: "v2")
        model.editNotes(key: "DB", inScope: "alpha", notes: "n")

        #expect(model.scopes.isEmpty)
        #expect(model.errorMessage == nil)
        #expect(model.statusMessage == nil)
    }

    @Test("every deletion intent is a no-op while no vault is open")
    func deletionsNoOpWithoutVault() {
        let model = noVaultModel()
        model.selectedScopeID = "alpha"
        model.selectedSecretKey = "DB"

        model.requestDeleteSelectedScope()
        model.confirmDeleteScope()
        model.requestDeleteSelectedSecret()
        model.confirmDeleteSecret()

        #expect(model.pendingScopeDeletion == nil)
        #expect(model.pendingSecretDeletion == nil)
        #expect(model.errorMessage == nil)
    }

    @Test("every drift intent is a no-op while no vault is open")
    func driftIntentsNoOpWithoutVault() async {
        let model = noVaultModel()

        await model.checkDrift()
        model.requestMaterializeAllStale()
        await model.confirmMaterializeAllStale()

        #expect(model.driftReports.isEmpty)
        #expect(model.allStalePlan == nil)
        #expect(model.statusMessage == nil)
    }

    @Test("ingest intents are no-ops while no vault is open")
    func ingestNoOpWithoutVault() async {
        let model = noVaultModel()

        await model.commitIngest()
        await model.presentIngestChooser()

        #expect(model.ingest.session == nil)
        #expect(model.errorMessage == nil)
    }

    // MARK: - Another action in flight

    @Test("intents that guard on activity are no-ops while one is in flight")
    func intentsNoOpWhileBusy() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("alpha", type: .other, in: vault)
            let model = openModel(vault: vault)
            model.selectedScopeID = "alpha"
            model.selectedSecretKey = "DB"
            let report = DriftReport(
                scopeID: "alpha",
                path: vault.appendingPathComponent(".env"),
                owned: [.fileMissing(key: "DB")],
                parseWarnings: []
            )
            model.driftReports = ["alpha": report]
            model.activity = .scanning
            defer { model.activity = nil }

            model.requestDeleteSelectedScope()
            model.requestDeleteSelectedSecret()
            model.requestMaterializeAllStale()
            await model.checkDrift()
            await model.confirmMaterializeAllStale()
            await model.commitIngest()
            await model.presentIngestChooser()

            #expect(model.pendingScopeDeletion == nil)
            #expect(model.pendingSecretDeletion == nil)
            #expect(model.allStalePlan == nil)
            #expect(model.errorMessage == nil)
        }
    }

    // MARK: - Confirm without a staged deletion

    @Test("confirming a deletion that was never staged does nothing")
    func confirmWithoutStagedDeletion() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("alpha", type: .other, in: vault)
            let model = openModel(vault: vault)

            model.confirmDeleteScope()
            model.confirmDeleteSecret()

            #expect(model.errorMessage == nil)
            #expect(model.statusMessage == nil)
            #expect(try VaultCore(vaultURL: vault).listScopes().count == 1)
        }
    }

    // MARK: - Empty-string normalization

    @Test("an empty display name or note is stored as absent, not as an empty string")
    func emptyStringsNormalizeToNil() throws {
        try AppAgeKeyFixture.withEphemeralKey { fixture in
            try WorkshopTestSupport.withTempVault { vault in
                let model = WorkshopModel(
                    environment: [
                        "SHARIBAKO_VAULT": vault.path,
                        "SHARIBAKO_AGE_KEY": fixture.privateKeyURL.path,
                    ],
                    home: URL(fileURLWithPath: "/Users/nobody")
                )

                model.addScope(id: "alpha", type: .other, displayName: "")
                model.addSecret(key: "DB", value: "v", notes: "", inScope: "alpha")
                model.addSharedEntry(id: "SHARED", value: "v", notes: "")
                model.editNotes(key: "DB", inScope: "alpha", notes: "")

                let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
                #expect(try core.listScopes().first?.displayName == nil)
                #expect(model.errorMessage == nil)
            }
        }
    }
}
