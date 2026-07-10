import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// ho-06.1 concurrency + scan-cache tests: the launch scan warms the cache,
/// Rescan refreshes it, materialize resolves from it without re-walking, the
/// miss-fallback runs exactly one fresh scan, the re-entry guard no-ops, and
/// `activity` clears on error paths.
///
/// All fixtures inject temp homes/roots/vaults — no live user state, no
/// Keychain, no signing (file-key path throughout).
@MainActor
@Suite("WorkshopModel Concurrency")
struct WorkshopModelConcurrencyTests {
    /// Seeds a project directory holding a `.sharibako` marker for `scope`
    /// under `root`, and returns the project directory.
    private static func seedMarker(
        scope: String,
        materializeTo: String = ".env",
        under root: URL,
        named dirName: String = "project"
    ) throws -> URL {
        let projectDir = root.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let markerContent = "scope: \(scope)\nmaterialize_to: \(materializeTo)\n"
        try markerContent.write(
            to: projectDir.appendingPathComponent(".sharibako"),
            atomically: true,
            encoding: .utf8
        )
        return projectDir
    }

    @Test("performLaunchScan warms the cache; cachedMarker resolves the scope")
    func launchScanWarmsCache() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let root = vault.deletingLastPathComponent().appendingPathComponent(
                "roots-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try Self.seedMarker(scope: "kanyo-dev", under: root)

            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.scanRoots = [root]
            // Cold before the launch scan.
            #expect(model.scanReport == nil)
            #expect(model.cachedMarker(forScope: "kanyo-dev") == nil)

            await model.performLaunchScan()

            #expect(model.scanReport != nil)
            #expect(model.cachedMarker(forScope: "kanyo-dev")?.scope == "kanyo-dev")
            // Launch scan is quiet on success — the user didn't trigger it.
            #expect(model.statusMessage == nil)
            #expect(model.errorMessage == nil)
            #expect(model.activity == nil)
        }
    }

    @Test("performLaunchScan is a no-op with no scan roots configured")
    func launchScanNoOpWithoutRoots() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            #expect(model.scanRoots.isEmpty)
            await model.performLaunchScan()
            // Nothing to scan — cache stays cold, no error, no activity.
            #expect(model.scanReport == nil)
            #expect(model.errorMessage == nil)
            #expect(model.activity == nil)
        }
    }

    @Test("rescan refreshes the cache with markers added since the launch scan")
    func rescanRefreshesCache() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("alpha", type: .other, in: vault)
            try WorkshopTestSupport.writeScope("beta", type: .other, in: vault)
            let root = vault.deletingLastPathComponent().appendingPathComponent(
                "roots-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try Self.seedMarker(scope: "alpha", under: root, named: "alpha-proj")

            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.scanRoots = [root]
            await model.performLaunchScan()
            #expect(model.cachedMarker(forScope: "alpha") != nil)
            #expect(model.cachedMarker(forScope: "beta") == nil)

            // A new marker appears after the launch scan.
            _ = try Self.seedMarker(scope: "beta", under: root, named: "beta-proj")

            await model.rescan()
            #expect(model.cachedMarker(forScope: "beta") != nil)
            #expect(model.statusMessage?.hasPrefix("Scan found 2 marker") == true)
        }
    }

    @Test("materialize resolves from the cache without re-scanning")
    func materializeResolvesFromCacheWithoutRescan() async throws {
        try await AppAgeKeyFixture.withEphemeralKey { fixture in
            try await WorkshopTestSupport.withTempVault { vault in
                try WorkshopTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
                let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
                try core.addSecret("DB", value: "postgres://x", inScope: "kanyo-dev")

                let root = vault.deletingLastPathComponent().appendingPathComponent(
                    "roots-\(UUID().uuidString)")
                try FileManager.default.createDirectory(
                    at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let projectDir = try Self.seedMarker(scope: "kanyo-dev", under: root)

                let model = WorkshopModel(
                    environment: [
                        "SHARIBAKO_VAULT": vault.path,
                        "SHARIBAKO_AGE_KEY": fixture.privateKeyURL.path,
                    ],
                    home: URL(fileURLWithPath: "/Users/nobody")
                )
                model.scanRoots = [root]
                model.selectedScopeID = "kanyo-dev"

                // Warm the cache.
                await model.performLaunchScan()
                #expect(model.cachedMarker(forScope: "kanyo-dev") != nil)

                // Delete the marker file: a FRESH scan would now find nothing.
                // The cache still holds the resolved marker, so materialize must
                // succeed without re-walking (Decision 2).
                try FileManager.default.removeItem(
                    at: projectDir.appendingPathComponent(".sharibako"))

                await model.materializeSelectedScope()
                #expect(model.errorMessage == nil)
                #expect(
                    FileManager.default.fileExists(
                        atPath: projectDir.appendingPathComponent(".env").path))
                #expect(model.statusMessage?.hasPrefix("Wrote 1 secret") == true)
                #expect(model.activity == nil)
            }
        }
    }

    @Test("materialize on a cold cache falls back to one fresh scan (miss-fallback)")
    func materializeMissFallbackScansOnce() async throws {
        try await AppAgeKeyFixture.withEphemeralKey { fixture in
            try await WorkshopTestSupport.withTempVault { vault in
                try WorkshopTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
                let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
                try core.addSecret("DB", value: "postgres://x", inScope: "kanyo-dev")

                let root = vault.deletingLastPathComponent().appendingPathComponent(
                    "roots-\(UUID().uuidString)")
                try FileManager.default.createDirectory(
                    at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let projectDir = try Self.seedMarker(scope: "kanyo-dev", under: root)

                let model = WorkshopModel(
                    environment: [
                        "SHARIBAKO_VAULT": vault.path,
                        "SHARIBAKO_AGE_KEY": fixture.privateKeyURL.path,
                    ],
                    home: URL(fileURLWithPath: "/Users/nobody")
                )
                model.scanRoots = [root]
                model.selectedScopeID = "kanyo-dev"

                // Cache is cold — never warmed. Materialize must fall back to a
                // fresh scan, populate the cache, and succeed.
                #expect(model.scanReport == nil)
                await model.materializeSelectedScope()
                #expect(model.errorMessage == nil)
                #expect(model.scanReport != nil)
                #expect(model.cachedMarker(forScope: "kanyo-dev") != nil)
                #expect(
                    FileManager.default.fileExists(
                        atPath: projectDir.appendingPathComponent(".env").path))
            }
        }
    }

    @Test("materialize surfaces marker-not-found when the fallback scan finds none")
    func materializeMissFallbackErrorsWhenAbsent() async throws {
        try await AppAgeKeyFixture.withEphemeralKey { fixture in
            try await WorkshopTestSupport.withTempVault { vault in
                try WorkshopTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
                let root = vault.deletingLastPathComponent().appendingPathComponent(
                    "roots-\(UUID().uuidString)")
                try FileManager.default.createDirectory(
                    at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                // No marker under the root at all.

                let model = WorkshopModel(
                    environment: [
                        "SHARIBAKO_VAULT": vault.path,
                        "SHARIBAKO_AGE_KEY": fixture.privateKeyURL.path,
                    ],
                    home: URL(fileURLWithPath: "/Users/nobody")
                )
                model.scanRoots = [root]
                model.selectedScopeID = "kanyo-dev"

                await model.materializeSelectedScope()
                // The one fresh scan found nothing → marker-not-found error,
                // and activity cleared on the error path.
                #expect(model.errorMessage != nil)
                #expect(model.activity == nil)
            }
        }
    }

    @Test("the re-entry guard no-ops a second intent while activity is non-nil")
    func reEntryGuardNoOps() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let root = vault.deletingLastPathComponent().appendingPathComponent(
                "roots-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try Self.seedMarker(scope: "alpha", under: root)

            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.scanRoots = [root]

            // A gate the worker's first submitted closure blocks on, so the
            // first rescan is provably in flight (activity set, suspended at the
            // worker) when the second call runs. Deterministic — no yields.
            let gate = DispatchSemaphore(value: 0)
            let entered = DispatchSemaphore(value: 0)
            let blocker = model.worker
            let hold = Task.detached {
                await blocker.run {
                    entered.signal()
                    gate.wait()
                }
            }
            // Wait until the worker is inside the blocking closure.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    entered.wait()
                    continuation.resume()
                }
            }

            // Kick off a real rescan: it sets activity, then suspends waiting
            // for the worker (which is busy behind the gate).
            let first = Task { await model.rescan() }
            // Let `first` run up to its `await worker.run` suspension.
            while model.activity == nil { await Task.yield() }
            #expect(model.activity == .scanning)

            // Second call while activity is non-nil: the guard no-ops it. It
            // returns immediately without touching statusMessage.
            await model.rescan()
            #expect(model.statusMessage == nil)
            #expect(model.activity == .scanning)

            // Release the gate; the first rescan completes and clears activity.
            gate.signal()
            _ = await hold.value
            await first.value
            #expect(model.activity == nil)
            #expect(model.statusMessage?.hasPrefix("Scan found") == true)
        }
    }

    @Test("Activity labels name the operation in flight for the status surface")
    func activityLabels() {
        #expect(WorkshopModel.Activity.scanning.label == "Scanning…")
        #expect(WorkshopModel.Activity.materializing.label == "Materializing…")
        #expect(WorkshopModel.Activity.syncing.label == "Syncing…")
    }

    @Test("sync clears activity on the error path")
    func syncClearsActivityOnError() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            // A vault with no git repository: Conduit(vaultURL:) init or commit
            // fails, routing to errorMessage. Either way, activity must clear.
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            await model.sync()
            #expect(model.errorMessage != nil)
            #expect(model.activity == nil)
        }
    }
}
