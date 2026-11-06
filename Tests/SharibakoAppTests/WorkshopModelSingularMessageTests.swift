import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// The singular arm of every count-dependent message the Workshop announces.
///
/// Each of these strings pluralizes inline (`count == 1 ? "" : "s"`), and the
/// suites that drive multi-scope fixtures only ever exercise the plural side.
/// A one-scope, one-secret, one-root vault is also the shape a first-run user
/// actually has, so this is the wording they see first.
@MainActor
@Suite("WorkshopModel singular messages")
struct WorkshopModelSingularMessageTests {
    /// A vault with exactly one scope owning exactly one secret, one scan root,
    /// one marker — everything at count 1.
    private static func withSingleEverything(
        _ body:
            @MainActor (_ model: WorkshopModel, _ envURL: URL) async throws -> Void
    ) async throws {
        try await AppAgeKeyFixture.withEphemeralKey { fixture in
            try await WorkshopTestSupport.withTempVault { vault in
                try WorkshopTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
                let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
                try core.addSecret("DB", value: "postgres://vault", inScope: "kanyo-dev")

                let root = vault.deletingLastPathComponent()
                    .appendingPathComponent("root-\(UUID().uuidString)")
                let projectDir = root.appendingPathComponent("kanyo")
                try FileManager.default.createDirectory(
                    at: projectDir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                try "scope: kanyo-dev\nmaterialize_to: .env\n".write(
                    to: projectDir.appendingPathComponent(".sharibako"),
                    atomically: true,
                    encoding: .utf8
                )

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

                try await body(model, projectDir.appendingPathComponent(".env"))
            }
        }
    }

    @Test("materializing one secret says 'secret', not 'secrets'")
    func materializeOneSecret() async throws {
        try await Self.withSingleEverything { model, envURL in
            await model.materializeSelectedScope()

            #expect(model.statusMessage?.hasPrefix("Wrote 1 secret to") == true)
            #expect(model.statusMessage?.contains("secrets") == false)
            #expect(FileManager.default.fileExists(atPath: envURL.path))
        }
    }

    @Test("rescanning one protected project says 'project', counted plainly")
    func rescanOneProject() async throws {
        try await Self.withSingleEverything { model, _ in
            await model.rescan()

            #expect(model.statusMessage == "Found no projects to protect; 1 already protected.")
        }
    }

    @Test("checking one scope says 'scope', not 'scopes'")
    func checkDriftOneScope() async throws {
        try await Self.withSingleEverything { model, _ in
            await model.materializeSelectedScope()

            await model.checkDrift()

            #expect(model.statusMessage?.hasPrefix("Checked 1 scope —") == true)
        }
    }

    @Test("a single drifted key reads 'key', and reconciling one scope reads 'scope'")
    func singleDriftedKeyAndScope() async throws {
        try await Self.withSingleEverything { model, envURL in
            await model.materializeSelectedScope()
            // Hand-edit the materialized value: exactly one key drifts.
            try "DB=hand-edited\n".write(to: envURL, atomically: true, encoding: .utf8)

            await model.checkDrift()

            let status = model.projectStatus(forScope: "kanyo-dev")
            #expect(status == .outOfDate(keyCount: 1))
            #expect(status.helpText.contains("1 secret in .env differs from the vault"))

            model.requestMaterializeAllStale()
            await model.confirmMaterializeAllStale()

            #expect(model.statusMessage == "Reconciled 1 of 1 drifted scope.")
        }
    }

    @Test("a scope with a drift report but no marker is skipped by both sweeps")
    func scopeWithoutMarkerIsSkipped() async throws {
        try await Self.withSingleEverything { model, _ in
            // A cached report for a scope that has no marker in the scan roots:
            // both the check sweep and the reconcile loop must step over it
            // rather than fail the whole run.
            model.driftReports["ghost"] = DriftReport(
                scopeID: "ghost",
                path: URL(fileURLWithPath: "/tmp/ghost/.env"),
                owned: [.fileMissing(key: "X")],
                parseWarnings: []
            )

            model.requestMaterializeAllStale()
            await model.confirmMaterializeAllStale()

            #expect(model.statusMessage == "Reconciled 0 of 1 drifted scope.")
            #expect(model.errorMessage == nil)
        }
    }
}
