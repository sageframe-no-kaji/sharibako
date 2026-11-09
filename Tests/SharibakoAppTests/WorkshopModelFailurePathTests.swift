import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// The Workshop model's failure arms — the `catch` blocks every intent ends in.
///
/// Two honest ways to make a bound vault fail without touching real user state:
/// yank the vault directory out from under an already-`.open` model (every
/// `VaultCore(vaultURL:)` then throws `vaultNotFound`), and point the file-key
/// dev seam at a path that does not exist (`loadIdentity` throws). Both are
/// states a user can actually reach — a vault on an ejected volume, a key file
/// moved after configuration — and neither needs the Keychain.
@MainActor
@Suite("WorkshopModel failure paths")
struct WorkshopModelFailurePathTests {
    /// A path that cannot resolve to an age key file.
    private static let missingKey = URL(fileURLWithPath: "/nonexistent/sharibako/age-key.txt")

    private func model(vault: URL, ageKey: URL? = nil) -> WorkshopModel {
        var environment = ["SHARIBAKO_VAULT": vault.path]
        if let ageKey { environment["SHARIBAKO_AGE_KEY"] = ageKey.path }
        return WorkshopModel(environment: environment, home: URL(fileURLWithPath: "/Users/nobody"))
    }

    /// Seeds a `.sharibako` naming `scope` under a fresh directory in `parent`.
    private static func seedMarker(scope: String, under parent: URL) throws -> URL {
        let root = parent.appendingPathComponent("roots-\(UUID().uuidString)")
        let projectDir = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try "scope: \(scope)\nmaterialize_to: .env\n".write(
            to: projectDir.appendingPathComponent(".sharibako"),
            atomically: true,
            encoding: .utf8
        )
        return root
    }

    // MARK: - Vault yanked mid-session

    @Test("performLaunchScan reports the failure when the vault has gone away")
    func launchScanFailsWithoutVault() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let model = model(vault: vault)
            model.scanRoots = [vault.deletingLastPathComponent()]
            try FileManager.default.removeItem(at: vault)

            await model.performLaunchScan()

            #expect(model.errorMessage != nil)
        }
    }

    @Test("rescan reports the failure when the vault has gone away")
    func rescanFailsWithoutVault() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let model = model(vault: vault)
            model.scanRoots = [vault.deletingLastPathComponent()]
            try FileManager.default.removeItem(at: vault)

            await model.rescan()

            #expect(model.errorMessage != nil)
        }
    }

    @Test("loading a page's lines reports the failure when the vault has gone away")
    func loadLinesFailsWithoutVault() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let model = model(vault: vault)
            let projectDir = vault.deletingLastPathComponent()
            model.selection = .candidate(directory: projectDir)
            try FileManager.default.removeItem(at: vault)

            await model.loadContent(for: model.selection)

            #expect(model.errorMessage != nil)
            #expect(model.envRead == nil)
        }
    }

    @Test("loading a project's lines reports the failure when the vault has gone away")
    func loadProjectLinesFailsWithoutVault() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("alpha", type: .other, in: vault)
            let model = model(vault: vault)
            model.selection = .project(scopeID: "alpha")
            try FileManager.default.removeItem(at: vault)

            await model.loadContent(for: model.selection)

            #expect(model.errorMessage != nil)
            #expect(model.secrets.isEmpty)
        }
    }

    @Test("confirmDeleteSecret reports the failure when the vault has gone away")
    func confirmDeleteSecretFailsWithoutVault() throws {
        try AppAgeKeyFixture.withEphemeralKey { fixture in
            try WorkshopTestSupport.withTempVault { vault in
                try WorkshopTestSupport.writeScope("alpha", type: .other, in: vault)
                let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
                try core.addSecret("DB", value: "postgres://vault", inScope: "alpha")

                let model = model(vault: vault, ageKey: fixture.privateKeyURL)
                model.selectedScopeID = "alpha"
                model.selectedSecretKey = "DB"
                model.requestDeleteSelectedSecret()
                try FileManager.default.removeItem(at: vault)

                model.confirmDeleteSecret()

                #expect(model.errorMessage != nil)
            }
        }
    }

    @Test("loadHistory surfaces a non-git failure rather than an empty history")
    func loadHistoryFailsWithoutVault() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("alpha", type: .other, in: vault)
            let model = model(vault: vault)
            try FileManager.default.removeItem(at: vault)

            model.loadHistory(for: "DB", inScope: "alpha", kind: .value)

            #expect(model.errorMessage != nil)
        }
    }

    // MARK: - Age key missing

    @Test("materializeSelectedScope says the age key could not be loaded")
    func materializeReportsMissingKey() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("alpha", type: .other, in: vault)
            let model = model(vault: vault, ageKey: Self.missingKey)
            model.selectedScopeID = "alpha"

            await model.materializeSelectedScope()

            #expect(model.errorMessage?.hasPrefix("Could not load age key:") == true)
        }
    }

    @Test("confirmMaterializeAllStale says the age key could not be loaded")
    func reconcileAllReportsMissingKey() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("alpha", type: .other, in: vault)
            let model = model(vault: vault, ageKey: Self.missingKey)
            let report = DriftReport(
                scopeID: "alpha",
                path: vault.appendingPathComponent(".env"),
                owned: [.fileMissing(key: "DB")],
                parseWarnings: []
            )
            model.driftReports = ["alpha": report]
            model.requestMaterializeAllStale()
            #expect(model.allStalePlan != nil)

            await model.confirmMaterializeAllStale()

            #expect(model.errorMessage?.hasPrefix("Could not load age key:") == true)
        }
    }

    @Test("checkDrift says the age key could not be loaded")
    func checkDriftReportsMissingKey() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let root = try Self.seedMarker(
                scope: "kanyo-dev", under: vault.deletingLastPathComponent())
            defer { try? FileManager.default.removeItem(at: root) }

            let model = model(vault: vault, ageKey: Self.missingKey)
            model.scanRoots = [root]
            await model.performLaunchScan()
            #expect(model.liveHereScopes.isEmpty == false)

            await model.checkDrift()

            #expect(model.errorMessage?.hasPrefix("Could not load age key:") == true)
        }
    }
}
