import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// ho-06.2 AT-02 tests: the pull-based drift cache and its reconciliation.
///
/// The pure classification helpers (`isDrifted`, `driftedKeyCount`, the label
/// mappings) are tested directly; the sweep, the badge/cache reads, per-scope
/// reconcile, and Materialize-all-stale are tested over injected temp vaults
/// with hand-drifted `.env` targets — asserting the computed cache state, never
/// rendering. The file-key dev path throughout: no Keychain, no signing.
@MainActor
@Suite("WorkshopModel Heal")
struct WorkshopModelHealTests {
    // MARK: - Fixtures

    /// A throwaway target path for the pure-classification reports.
    private static let tmpEnv = URL(fileURLWithPath: "/tmp/.env")

    /// Builds a `DriftReport` over `owned` for the pure classification tests.
    private static func report(_ owned: [KeyDrift]) -> DriftReport {
        DriftReport(scopeID: "s", path: tmpEnv, owned: owned, parseWarnings: [])
    }

    /// Seeds a `.sharibako` under `root` naming `scope`, returns the project dir.
    private static func seedMarker(scope: String, under root: URL, named dir: String) throws -> URL {
        let projectDir = root.appendingPathComponent(dir)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try "scope: \(scope)\nmaterialize_to: .env\n".write(
            to: projectDir.appendingPathComponent(".sharibako"),
            atomically: true,
            encoding: .utf8
        )
        return projectDir
    }

    /// A vault with one materialized scope (`kanyo-dev`, owning `DB`), its
    /// marker warmed into the scan cache, and its `.env` written.
    ///
    /// Hands `body` the model, the project dir, and the `.env` URL so a test can
    /// hand-drift the file and run the sweep.
    private static func withMaterializedScope(
        _ body:
            @MainActor (_ model: WorkshopModel, _ projectDir: URL, _ envURL: URL) async throws ->
            Void
    ) async throws {
        try await AppAgeKeyFixture.withEphemeralKey { fixture in
            try await WorkshopTestSupport.withTempVault { vault in
                try WorkshopTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
                let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
                try core.addSecret("DB", value: "postgres://vault", inScope: "kanyo-dev")

                let root = vault.deletingLastPathComponent().appendingPathComponent(
                    "roots-\(UUID().uuidString)")
                try FileManager.default.createDirectory(
                    at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let projectDir = try Self.seedMarker(scope: "kanyo-dev", under: root, named: "kanyo")

                let model = WorkshopModel(
                    environment: [
                        "SHARIBAKO_VAULT": vault.path,
                        "SHARIBAKO_AGE_KEY": fixture.privateKeyURL.path,
                    ],
                    home: URL(fileURLWithPath: "/Users/nobody")
                )
                model.scanRoots = [root]
                model.selectedScopeID = "kanyo-dev"
                await model.performLaunchScan()
                await model.materializeSelectedScope()  // writes .env, no drift yet

                let envURL = projectDir.appendingPathComponent(".env")
                try await body(model, projectDir, envURL)
            }
        }
    }

    // MARK: - Pure classification

    @Test("isDrifted is false for an all-match report, true when any key drifts")
    func isDriftedAcrossCases() {
        #expect(WorkshopModel.isDrifted(Self.report([.match(key: "A"), .match(key: "B")])) == false)
        #expect(
            WorkshopModel.isDrifted(
                Self.report([
                    .match(key: "A"),
                    .fileValueDiffers(key: "B", vaultSha256: "x", fileSha256: "y"),
                ])))
        #expect(WorkshopModel.isDrifted(Self.report([.fileMissing(key: "A")])))
        #expect(
            WorkshopModel.isDrifted(
                Self.report([.match(key: "A"), .fileLineCorrupted(key: "B")])))
    }

    @Test("driftedKeyCount counts every non-match owned key")
    func driftedKeyCount() {
        let report = Self.report([
            .match(key: "A"),
            .fileMissing(key: "B"),
            .fileValueDiffers(key: "C", vaultSha256: "x", fileSha256: "y"),
            .fileLineCorrupted(key: "D"),
        ])
        #expect(WorkshopModel.driftedKeyCount(report) == 3)
    }

    @Test("driftStatusLabel and driftKey render each KeyDrift case")
    func driftLabelAndKey() {
        #expect(WorkshopModel.driftStatusLabel(for: .match(key: "A")) == "In sync")
        #expect(WorkshopModel.driftStatusLabel(for: .fileMissing(key: "A")) == "Missing from file")
        #expect(
            WorkshopModel.driftStatusLabel(
                for: .fileValueDiffers(key: "A", vaultSha256: "x", fileSha256: "y")) == "Differs")
        #expect(
            WorkshopModel.driftStatusLabel(for: .fileLineCorrupted(key: "A")) == "Malformed line")

        #expect(WorkshopModel.driftKey(.match(key: "K")) == "K")
        #expect(WorkshopModel.driftKey(.fileMissing(key: "K")) == "K")
        #expect(
            WorkshopModel.driftKey(.fileValueDiffers(key: "K", vaultSha256: "x", fileSha256: "y"))
                == "K")
        #expect(WorkshopModel.driftKey(.fileLineCorrupted(key: "K")) == "K")
    }

    @Test("DriftBadge carries a shape-distinct symbol and a naming tooltip per state")
    func driftBadgePresentation() {
        let clean = WorkshopModel.DriftBadge.clean
        let drifted = WorkshopModel.DriftBadge.drifted(keyCount: 2)
        #expect(clean.symbolName != drifted.symbolName)
        #expect(!clean.helpText.isEmpty)
        #expect(drifted.helpText.contains("2"))
    }

    // MARK: - Cache reads before a check

    @Test("driftBadge and driftReport are nil before any check has run")
    func cacheEmptyBeforeCheck() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            #expect(model.driftBadge(forScope: "kanyo-dev") == nil)
            #expect(model.driftReport(forScope: "kanyo-dev") == nil)
            #expect(model.driftReports.isEmpty)
        }
    }

    // MARK: - Check-drift sweep

    @Test("checkDrift with no live-here scopes announces and spends no age key")
    func checkDriftNoCandidates() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let root = vault.deletingLastPathComponent().appendingPathComponent(
                "roots-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            // No marker → the scope is live-elsewhere → no sweep candidates.
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.scanRoots = [root]
            await model.performLaunchScan()
            await model.checkDrift()
            #expect(model.statusMessage == "No materialized scopes to check for drift.")
            #expect(model.driftReports.isEmpty)
            #expect(model.activity == nil)
        }
    }

    @Test("checkDrift caches a clean report when the .env matches the vault")
    func checkDriftClean() async throws {
        try await Self.withMaterializedScope { model, _, _ in
            await model.checkDrift()
            #expect(model.driftReports["kanyo-dev"] != nil)
            #expect(model.driftBadge(forScope: "kanyo-dev") == .clean)
            #expect(model.statusMessage == "Checked 1 scope — 0 drifted.")
            #expect(model.errorMessage == nil)
            #expect(model.activity == nil)
        }
    }

    @Test("checkDrift detects a hand-edited owned value as drift")
    func checkDriftDetectsDrift() async throws {
        try await Self.withMaterializedScope { model, _, envURL in
            // Tamper the materialized value — owned key DB now differs.
            try "DB=postgres://tampered\n".write(to: envURL, atomically: true, encoding: .utf8)
            await model.checkDrift()

            guard let report = model.driftReports["kanyo-dev"] else {
                Issue.record("Expected a cached drift report")
                return
            }
            #expect(WorkshopModel.isDrifted(report))
            #expect(model.driftBadge(forScope: "kanyo-dev") == .drifted(keyCount: 1))
            #expect(model.statusMessage == "Checked 1 scope — 1 drifted.")
        }
    }

    // MARK: - Per-scope reconcile

    @Test("a forced reconcile writes the vault value back and clears the scope's cached drift")
    func reconcileClearsDrift() async throws {
        try await Self.withMaterializedScope { model, _, envURL in
            try "DB=postgres://tampered\n".write(to: envURL, atomically: true, encoding: .utf8)
            await model.checkDrift()
            #expect(model.driftBadge(forScope: "kanyo-dev") == .drifted(keyCount: 1))

            // Reconcile: the UI routes Reconcile → materializeSelectedScope()
            // → drift confirmation → materializeSelectedScope(force: true).
            await model.materializeSelectedScope(force: true)
            #expect(model.errorMessage == nil)

            // The file is back in sync and the stale badge is gone.
            let contents = try String(contentsOf: envURL, encoding: .utf8)
            #expect(contents.contains("DB=postgres://vault"))
            #expect(model.driftReports["kanyo-dev"] == nil)
            #expect(model.driftBadge(forScope: "kanyo-dev") == nil)
        }
    }

    // MARK: - Materialize all stale

    @Test("requestMaterializeAllStale prompts to check first when the cache is empty")
    func allStalePromptsToCheckFirst() throws {
        try WorkshopTestSupport.withTempVault { vault in
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.requestMaterializeAllStale()
            #expect(model.allStalePlan == nil)
            #expect(model.statusMessage == "Check drift first — there's no drift information yet.")
        }
    }

    @Test("requestMaterializeAllStale stages the drifted scopes and target paths")
    func allStaleStagesPlan() async throws {
        try await Self.withMaterializedScope { model, _, envURL in
            try "DB=postgres://tampered\n".write(to: envURL, atomically: true, encoding: .utf8)
            await model.checkDrift()
            model.requestMaterializeAllStale()

            guard let plan = model.allStalePlan else {
                Issue.record("Expected an all-stale plan")
                return
            }
            #expect(plan.scopeIDs == ["kanyo-dev"])
            #expect(plan.targetPaths.count == 1)
            #expect(plan.targetPaths.first?.hasSuffix(".env") == true)
        }
    }

    @Test("confirmMaterializeAllStale reconciles the drifted set and clears their drift")
    func allStaleReconciles() async throws {
        try await Self.withMaterializedScope { model, _, envURL in
            try "DB=postgres://tampered\n".write(to: envURL, atomically: true, encoding: .utf8)
            await model.checkDrift()
            model.requestMaterializeAllStale()
            #expect(model.allStalePlan != nil)

            await model.confirmMaterializeAllStale()
            #expect(model.errorMessage == nil)
            #expect(model.allStalePlan == nil)

            let contents = try String(contentsOf: envURL, encoding: .utf8)
            #expect(contents.contains("DB=postgres://vault"))
            #expect(model.driftReports["kanyo-dev"] == nil)
            #expect(model.statusMessage == "Reconciled 1 of 1 drifted scope.")
        }
    }
}
