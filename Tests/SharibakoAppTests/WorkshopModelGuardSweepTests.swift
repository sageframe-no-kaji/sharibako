import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// The second half of the guard sweep (see `WorkshopModelGuardTests`): the
/// read/refresh intents and the long-running async verbs, checked against the
/// same two conditions — no vault open, and another action already in flight.
///
/// Split into its own suite to keep both bodies under the linter's
/// type-body-length ceiling.
@MainActor
@Suite("WorkshopModel guard sweep")
struct WorkshopModelGuardSweepTests {
    private func noVaultModel() -> WorkshopModel {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharibako-sweep-\(UUID().uuidString)")
        return FirstRunTestSupport.noVaultModel(home: home)
    }

    private func openModel(vault: URL) -> WorkshopModel {
        WorkshopModel(
            environment: ["SHARIBAKO_VAULT": vault.path],
            home: URL(fileURLWithPath: "/Users/nobody")
        )
    }

    // MARK: - No vault open

    @Test("read intents are no-ops while no vault is open")
    func readsNoOpWithoutVault() {
        let model = noVaultModel()

        model.loadSecrets(for: "alpha")
        model.reveal(key: "DB", inScope: "alpha")
        model.loadHistory(for: "DB", inScope: "alpha", kind: .value)

        #expect(model.secrets.isEmpty)
        #expect(model.revealedValue == nil)
        #expect(model.errorMessage == nil)
    }

    @Test("the async verbs are no-ops while no vault is open")
    func asyncVerbsNoOpWithoutVault() async {
        let model = noVaultModel()

        await model.performLaunchScan()
        await model.materializeSelectedScope()
        await model.sync()
        await model.rescan()

        #expect(model.scanReport == nil)
        #expect(model.statusMessage == nil)
        #expect(model.errorMessage == nil)
    }

    // MARK: - Another action in flight

    @Test("the async verbs are no-ops while another action is in flight")
    func asyncVerbsNoOpWhileBusy() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("alpha", type: .other, in: vault)
            let model = openModel(vault: vault)
            model.selectedScopeID = "alpha"
            model.activity = .syncing
            defer { model.activity = nil }

            await model.performLaunchScan()
            await model.materializeSelectedScope()
            await model.sync()

            #expect(model.scanReport == nil)
            #expect(model.statusMessage == nil)
            #expect(model.errorMessage == nil)
        }
    }

    // MARK: - Vault readable at bind time, gone at read time

    @Test("loadSecrets gives up quietly when the vault can no longer be opened")
    func loadSecretsAfterVaultRemoved() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("alpha", type: .other, in: vault)
            let model = openModel(vault: vault)
            model.loadSecrets(for: "alpha")
            #expect(model.secrets.isEmpty)

            try FileManager.default.removeItem(at: vault)
            model.loadSecrets(for: "alpha")

            #expect(model.secrets.isEmpty)
        }
    }

    // MARK: - Drift refresh without a selection

    @Test("refreshDriftForSelectedScopeAfterWrite is a no-op with nothing selected")
    func refreshDriftWithoutSelection() throws {
        try WorkshopTestSupport.withTempVault { vault in
            let model = openModel(vault: vault)
            model.selectedScopeID = nil

            model.refreshDriftForSelectedScopeAfterWrite()

            #expect(model.driftReports.isEmpty)
        }
    }

    // MARK: - Activity labels

    @Test("every activity has progress text")
    func activityLabels() {
        #expect(WorkshopModel.Activity.scanning.label == "Scanning…")
        #expect(WorkshopModel.Activity.materializing.label == "Materializing…")
        #expect(WorkshopModel.Activity.syncing.label == "Syncing…")
        #expect(WorkshopModel.Activity.checkingDrift.label == "Checking every project…")
        #expect(WorkshopModel.Activity.unprotecting.label == "Unprotecting…")
        #expect(WorkshopModel.Activity.ingesting.label == "Protecting…")
    }
}
