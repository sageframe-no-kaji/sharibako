import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// Tests for the "Unlinked markers" orphan-remediation intents (ho-06.3
/// AT-03, `WorkshopModel+Orphans.swift`) — `createScopeFromMarker` and the
/// `requestRemoveStrayMarker`/`confirmRemoveStrayMarker`/
/// `dismissStrayMarkerRemoval` trio.
///
/// `createScopeFromMarker` rides `beginIngest`/`commitIngest`, which encrypt,
/// so those legs use `AppAgeKeyFixture` (the `WorkshopModelIngestCommitTests`
/// convention). Removal is keyless — no Keychain, no age key, no Touch ID —
/// so those legs use plain temp vaults, mirroring `WorkshopModelDeleteTests`.
/// All fixtures inject temp homes/roots/vaults — no live user state.
@MainActor
@Suite("WorkshopModel Orphans")
struct WorkshopModelOrphansTests {
    /// Writes `contents` to `<directory>/<name>`, creating `directory`
    /// first — mirrors `WorkshopModelIngestTests.writeEnv`.
    private static func writeEnv(
        _ contents: String, in directory: URL, named name: String = ".env"
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try contents.write(
            to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// Seeds a `.sharibako` under `root` naming `scope` — mirrors
    /// `WorkshopModelGlyphsTests.seedMarker`.
    private static func seedMarker(
        scope: String,
        under root: URL,
        named dirName: String
    ) throws -> URL {
        let projectDir = root.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try "scope: \(scope)\nmaterialize_to: .env\n".write(
            to: projectDir.appendingPathComponent(".sharibako"),
            atomically: true,
            encoding: .utf8
        )
        return projectDir
    }

    /// A fresh temp scan root, cleaned up by the caller's `defer`.
    private static func makeRoot(near vault: URL) throws -> URL {
        let root = vault.deletingLastPathComponent().appendingPathComponent(
            "roots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// The marker's on-disk URL, however the `UnlinkedMarker` case carries it.
    ///
    /// Assertions below compare against URLs the model itself produced
    /// (through a real scan) rather than URLs this file constructs from
    /// `root` — `FileManager.temporaryDirectory` resolves through `/private`
    /// on macOS, so a locally-built path and a scanned one can differ by that
    /// symlink alone even when they name the same file.
    private static func markerURL(of marker: WorkshopModel.UnlinkedMarker) -> URL {
        switch marker {
        case .orphaned(_, let markerURL): return markerURL
        case .failed(let markerURL, _): return markerURL
        }
    }

    private func model(vault: URL) -> WorkshopModel {
        WorkshopModel(
            environment: ["SHARIBAKO_VAULT": vault.path],
            home: URL(fileURLWithPath: "/Users/nobody")
        )
    }

    // MARK: - createScopeFromMarker

    @Test("createScopeFromMarker seeds the ingest session with the marker's directory and scope ID")
    func createScopeFromMarkerSeedsSession() async throws {
        try await AppAgeKeyFixture.withEphemeralKey { fixture in
            try await WorkshopTestSupport.withTempVault { vault in
                let root = try Self.makeRoot(near: vault)
                defer { try? FileManager.default.removeItem(at: root) }
                let project = try Self.seedMarker(scope: "ghost-scope", under: root, named: "ghost")
                try Self.writeEnv("API_KEY=sk-live\n", in: project)

                let model = WorkshopModel(
                    environment: [
                        "SHARIBAKO_VAULT": vault.path,
                        "SHARIBAKO_AGE_KEY": fixture.privateKeyURL.path,
                    ],
                    home: URL(fileURLWithPath: "/Users/nobody")
                )
                model.scanRoots = [root]
                await model.performLaunchScan()
                let orphan = try #require(model.unlinkedMarkers.first)
                let expectedDirectory = Self.markerURL(of: orphan).deletingLastPathComponent()

                await model.createScopeFromMarker(orphan)

                #expect(model.ingest.session?.directory == expectedDirectory)
                #expect(model.ingest.session?.scopeID == "ghost-scope")
                #expect(model.ingest.session?.isReconcile == true)
                #expect(model.ingest.session?.decisions.keys.contains("API_KEY") == true)
            }
        }
    }

    @Test("createScopeFromMarker is a no-op for a scan-failure row")
    func createScopeFromMarkerNoOpForFailure() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let markerURL = vault.appendingPathComponent("nowhere/.sharibako")
            let failure = WorkshopModel.UnlinkedMarker.failed(
                markerURL: markerURL, reason: "bad yaml")
            let model = model(vault: vault)

            await model.createScopeFromMarker(failure)

            #expect(model.ingest.session == nil)
        }
    }

    @Test("committing a marker-seeded session creates the scope and clears the orphan")
    func createScopeFromMarkerRoundTrips() async throws {
        try await AppAgeKeyFixture.withEphemeralKey { fixture in
            try await WorkshopTestSupport.withTempVault { vault in
                let root = try Self.makeRoot(near: vault)
                defer { try? FileManager.default.removeItem(at: root) }
                let project = try Self.seedMarker(scope: "ghost-scope", under: root, named: "ghost")
                try Self.writeEnv("API_KEY=sk-live\n", in: project)

                let model = WorkshopModel(
                    environment: [
                        "SHARIBAKO_VAULT": vault.path,
                        "SHARIBAKO_AGE_KEY": fixture.privateKeyURL.path,
                    ],
                    home: URL(fileURLWithPath: "/Users/nobody")
                )
                model.scanRoots = [root]
                await model.performLaunchScan()
                let orphan = try #require(model.unlinkedMarkers.first)

                await model.createScopeFromMarker(orphan)
                await model.commitIngest()

                #expect(model.scopes.map(\.identity).contains("ghost-scope"))
                #expect(model.unlinkedMarkers.isEmpty)
                #expect(model.glyphState(forScope: "ghost-scope") == .liveHere)
            }
        }
    }

    // MARK: - requestRemoveStrayMarker

    @Test("requestRemoveStrayMarker stages a pending removal for an orphaned marker")
    func requestStagesPending() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let root = try Self.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try Self.seedMarker(scope: "ghost-scope", under: root, named: "ghost")

            let model = model(vault: vault)
            model.scanRoots = [root]
            await model.performLaunchScan()
            let orphan = try #require(model.unlinkedMarkers.first)
            let expectedMarkerURL = Self.markerURL(of: orphan)

            model.requestRemoveStrayMarker(orphan)

            #expect(model.pendingStrayMarkerRemoval?.scope == "ghost-scope")
            #expect(model.pendingStrayMarkerRemoval?.markerURL == expectedMarkerURL)
        }
    }

    @Test("requestRemoveStrayMarker is a no-op for a scan-failure row")
    func requestNoOpForFailure() throws {
        try WorkshopTestSupport.withTempVault { vault in
            let markerURL = vault.appendingPathComponent("nowhere/.sharibako")
            let failure = WorkshopModel.UnlinkedMarker.failed(
                markerURL: markerURL, reason: "bad yaml")
            let model = model(vault: vault)

            model.requestRemoveStrayMarker(failure)

            #expect(model.pendingStrayMarkerRemoval == nil)
        }
    }

    @Test("requestRemoveStrayMarker is a no-op while another activity is in flight")
    func requestNoOpDuringActivity() throws {
        try WorkshopTestSupport.withTempVault { vault in
            let orphan = WorkshopModel.UnlinkedMarker.orphaned(
                scope: "ghost-scope",
                markerURL: vault.appendingPathComponent("ghost/.sharibako")
            )
            let model = model(vault: vault)
            model.activity = .scanning

            model.requestRemoveStrayMarker(orphan)

            #expect(model.pendingStrayMarkerRemoval == nil)
        }
    }

    // MARK: - confirmRemoveStrayMarker

    @Test("confirmRemoveStrayMarker deletes the marker file, refreshes the cache, and announces")
    func confirmRemovesMarker() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let root = try Self.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            let project = try Self.seedMarker(scope: "ghost-scope", under: root, named: "ghost")
            let markerURL = project.appendingPathComponent(".sharibako")

            let model = model(vault: vault)
            model.scanRoots = [root]
            await model.performLaunchScan()
            let orphan = try #require(model.unlinkedMarkers.first)
            model.requestRemoveStrayMarker(orphan)

            model.confirmRemoveStrayMarker()

            #expect(model.pendingStrayMarkerRemoval == nil)
            #expect(!FileManager.default.fileExists(atPath: markerURL.path))
            #expect(model.unlinkedMarkers.isEmpty)
            #expect(model.scanReport?.markers.isEmpty == true)
            #expect(model.statusMessage?.contains("ghost-scope") == true)
            #expect(model.statusMessage?.contains(markerURL.path) == true)
            #expect(model.errorMessage == nil)
            // The vault itself is untouched — still no scopes.
            #expect(try VaultCore(vaultURL: vault).listScopes().isEmpty)
        }
    }

    @Test("confirmRemoveStrayMarker leaves scan-failure rows untouched")
    func confirmLeavesFailuresUntouched() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let root = try Self.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try Self.seedMarker(scope: "real-scope", under: root, named: "real")
            try WorkshopTestSupport.writeScope("real-scope", type: .other, in: vault)
            let brokenDir = root.appendingPathComponent("broken")
            try FileManager.default.createDirectory(at: brokenDir, withIntermediateDirectories: true)
            try "scope: legit\nmaterialize_to: /etc/passwd\n".write(
                to: brokenDir.appendingPathComponent(".sharibako"),
                atomically: true,
                encoding: .utf8
            )
            _ = try Self.seedMarker(scope: "ghost-scope", under: root, named: "ghost")

            let model = model(vault: vault)
            model.scanRoots = [root]
            await model.performLaunchScan()
            let orphan = try #require(
                model.unlinkedMarkers.first { marker in
                    if case .orphaned = marker { return true }
                    return false
                })
            model.requestRemoveStrayMarker(orphan)

            model.confirmRemoveStrayMarker()

            #expect(model.unlinkedMarkers.count == 1)
            guard case .failed = model.unlinkedMarkers.first else {
                Issue.record("Expected the scan-failure row to survive the removal")
                return
            }
        }
    }

    @Test("confirmRemoveStrayMarker surfaces an error and stays consistent when the file is already gone")
    func confirmAbsentSurfacesError() throws {
        try WorkshopTestSupport.withTempVault { vault in
            let ghostURL = vault.appendingPathComponent("nowhere/.sharibako")
            let model = model(vault: vault)
            model.pendingStrayMarkerRemoval = WorkshopModel.StrayMarkerRemoval(
                scope: "ghost-scope", markerURL: ghostURL)

            model.confirmRemoveStrayMarker()

            #expect(model.pendingStrayMarkerRemoval == nil)
            #expect(model.errorMessage != nil)
        }
    }

    @Test("confirmRemoveStrayMarker is a no-op with nothing staged")
    func confirmNoOpWithoutStaged() throws {
        try WorkshopTestSupport.withTempVault { vault in
            let model = model(vault: vault)

            model.confirmRemoveStrayMarker()

            #expect(model.errorMessage == nil)
            #expect(model.statusMessage == nil)
        }
    }

    // MARK: - dismissStrayMarkerRemoval

    @Test("dismissStrayMarkerRemoval clears the pending removal without deleting the file")
    func dismissClears() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let root = try Self.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            let project = try Self.seedMarker(scope: "ghost-scope", under: root, named: "ghost")
            let markerURL = project.appendingPathComponent(".sharibako")

            let model = model(vault: vault)
            model.scanRoots = [root]
            await model.performLaunchScan()
            let orphan = try #require(model.unlinkedMarkers.first)
            model.requestRemoveStrayMarker(orphan)

            model.dismissStrayMarkerRemoval()

            #expect(model.pendingStrayMarkerRemoval == nil)
            #expect(FileManager.default.fileExists(atPath: markerURL.path))
        }
    }
}
