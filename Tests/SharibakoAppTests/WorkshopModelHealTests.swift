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

    // MARK: - Cache reads before a check

    @Test("no drift report and no Out-of-date status before any check has run")
    func cacheEmptyBeforeCheck() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            #expect(model.projectStatus(forScope: "kanyo-dev") == .noFolderHere)
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
            #expect(model.statusMessage == "No protected projects with a folder on this Mac to check.")
            #expect(model.driftReports.isEmpty)
            #expect(model.activity == nil)
        }
    }

    @Test("checkDrift caches a clean report when the .env matches the vault")
    func checkDriftClean() async throws {
        try await Self.withMaterializedScope { model, _, _ in
            await model.checkDrift()
            #expect(model.driftReports["kanyo-dev"] != nil)
            #expect(model.projectStatus(forScope: "kanyo-dev") == .protected)
            #expect(model.statusMessage == "1 checked · 0 out of date")
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
            #expect(model.projectStatus(forScope: "kanyo-dev") == .outOfDate(keyCount: 1))
            #expect(model.statusMessage == "1 checked · 1 out of date")
        }
    }

    // MARK: - Per-scope reconcile

    @Test("a forced reconcile writes the vault value back and marks the scope in sync")
    func reconcileMarksInSync() async throws {
        try await Self.withMaterializedScope { model, _, envURL in
            try "DB=postgres://tampered\n".write(to: envURL, atomically: true, encoding: .utf8)
            await model.checkDrift()
            #expect(model.projectStatus(forScope: "kanyo-dev") == .outOfDate(keyCount: 1))

            // Reconcile: the UI routes Reconcile → materializeSelectedScope()
            // → drift confirmation → materializeSelectedScope(force: true).
            await model.materializeSelectedScope(force: true)
            #expect(model.errorMessage == nil)

            // The file is back in sync. The cached report is REFRESHED to
            // all-match (not cleared) so the detail pane stays on the drift view
            // showing "In sync" and the badge flips to clean — not a blank
            // window (06.2 gate finding).
            let contents = try String(contentsOf: envURL, encoding: .utf8)
            #expect(contents.contains("DB=postgres://vault"))
            guard let report = model.driftReports["kanyo-dev"] else {
                Issue.record("Expected a refreshed in-sync report, not a cleared entry")
                return
            }
            #expect(WorkshopModel.isDrifted(report) == false)
            #expect(model.projectStatus(forScope: "kanyo-dev") == .protected)
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

    @Test("confirmMaterializeAllStale reconciles the drifted set and marks them in sync")
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
            // Refreshed to clean, not cleared (same gate finding as reconcile).
            #expect(model.projectStatus(forScope: "kanyo-dev") == .protected)
            #expect(model.statusMessage == "Reconciled 1 of 1 drifted scope.")
        }
    }

    @Test("keyDrift returns the selected key's drift, or nil before a check / for an unowned key")
    func keyDriftLookup() async throws {
        try await Self.withMaterializedScope { model, _, envURL in
            // Before a check: nil for any key.
            #expect(model.keyDrift(forScope: "kanyo-dev", key: "DB") == nil)

            try "DB=postgres://tampered\n".write(to: envURL, atomically: true, encoding: .utf8)
            await model.checkDrift()

            let drift = model.keyDrift(forScope: "kanyo-dev", key: "DB")
            #expect(drift != nil)
            #expect(drift.map(WorkshopModel.isKeyDrifted) == true)
            // A key the scope does not own has no drift entry.
            #expect(model.keyDrift(forScope: "kanyo-dev", key: "NOT_A_KEY") == nil)
        }
    }

    @Test("isKeyDrifted is false only for .match")
    func isKeyDriftedAcrossCases() {
        #expect(WorkshopModel.isKeyDrifted(.match(key: "A")) == false)
        #expect(WorkshopModel.isKeyDrifted(.fileMissing(key: "A")))
        #expect(
            WorkshopModel.isKeyDrifted(.fileValueDiffers(key: "A", vaultSha256: "x", fileSha256: "y")))
        #expect(WorkshopModel.isKeyDrifted(.fileLineCorrupted(key: "A")))
    }
}

/// ho-06.10 AT-04 tests: Check all keeps going past projects this key cannot
/// read, reports per project, and notices a protected value equal to a
/// shared secret's.
@MainActor
@Suite("WorkshopModel Check all")
struct WorkshopModelCheckAllTests {
    @Test("Check all's announce: checked and out of date always, the rest only when there are some")
    func checkAllSummary() {
        #expect(
            WorkshopModel.checkAllSummary(checked: 4, outOfDate: 1, unreadable: 2, matches: 0)
                == "4 checked · 1 out of date · 2 could not be read")
        #expect(
            WorkshopModel.checkAllSummary(checked: 1, outOfDate: 0, unreadable: 0, matches: 0)
                == "1 checked · 0 out of date")
        #expect(
            WorkshopModel.checkAllSummary(checked: 2, outOfDate: 0, unreadable: 0, matches: 1)
                == "2 checked · 0 out of date · 1 line matches a shared secret")
        #expect(
            WorkshopModel.checkAllSummary(checked: 2, outOfDate: 0, unreadable: 1, matches: 3)
                == "2 checked · 0 out of date · 1 could not be read · 3 lines match a shared secret")
    }

    @Test("Check all with two unreadable projects still checks the rest and reports all three counts")
    func checkAllContinuesPastUnreadable() async throws {
        try await AppAgeKeyFixture.withEphemeralKey { fixture in
            try await AppAgeKeyFixture.withEphemeralKey { other in
                try await WorkshopTestSupport.withTempVault { vault in
                    let root = try ProjectsTestSupport.makeRoot(near: vault)
                    defer { try? FileManager.default.removeItem(at: root) }
                    let mine = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
                    let theirs = try VaultCore(vaultURL: vault, ageKeyURL: other.privateKeyURL)
                    for (scope, core) in [("bento", mine), ("ghost", theirs), ("relic", theirs)] {
                        try WorkshopTestSupport.writeScope(scope, type: .projectDev, in: vault)
                        try core.addSecret("DB", value: "postgres://\(scope)", inScope: scope)
                        let folder = try ProjectsTestSupport.seedMarker(scope: scope, under: root, named: scope)
                        try ProjectsTestSupport.writeEnv("DB=postgres://\(scope)\n", in: folder)
                    }
                    let model = ProjectsTestSupport.model(vault: vault, ageKey: fixture.privateKeyURL)
                    model.scanRoots = [root]
                    await model.performLaunchScan()

                    await model.checkDrift()
                    #expect(model.statusMessage == "1 checked · 0 out of date · 2 could not be read")
                    #expect(Set(model.driftReports.keys) == ["bento"])
                    #expect(Set(model.unreadableProjects.keys) == ["ghost", "relic"])
                    #expect(model.errorMessage == nil)
                    #expect(model.activity == nil)

                    model.selection = .project(scopeID: "ghost")
                    let error = try #require(model.paneError(in: .page))
                    #expect(error.message == WorkshopModel.keyMismatchMessage)
                    #expect(error.nextStep == WorkshopModel.keyMismatchNextStep)
                    model.selection = .project(scopeID: "bento")
                    #expect(model.paneError(in: .page) == nil)
                }
            }
        }
    }

    @Test("a protected value equal to a shared secret's is noticed; an unreadable shared secret is skipped")
    func checkAllValueMatch() async throws {
        try await AppAgeKeyFixture.withEphemeralKey { other in
            try await VerbsTestSupport.withProtectedProject(
                env: "DB=postgres://vault\nAPI_KEY=sk-live\n", shared: ["openai": "sk-live", "pg": "postgres://x"]
            ) { model, vault, _, _ in
                // A shared secret this key cannot read is left out, not fatal.
                try VaultCore(vaultURL: vault, ageKeyURL: other.privateKeyURL).addSharedEntry(
                    "theirs", value: "sk-live")
                model.loadScopes()
                await model.checkDrift()
                #expect(model.sharedMatches == ["bento": ["API_KEY": "openai"]])
                #expect(model.statusMessage == "1 checked · 0 out of date · 1 line matches a shared secret")

                model.forgetCheckResults(forScope: "bento")
                #expect(model.sharedMatches.isEmpty)
                #expect(model.driftReports.isEmpty)
            }
        }
    }
}
