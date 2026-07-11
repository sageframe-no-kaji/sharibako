import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// ho-06.2 AT-01 tests: glyph state and the "Unlinked markers" derivation.
///
/// `glyphState(forScope:)` over the scan cache, and the orphan + scan-failure
/// derivation. All state is computed from cached data — the tests warm the
/// cache through `performLaunchScan()` (the only writer of the `private(set)
/// scanReport`), then assert the computed glyph/orphan state, never rendering.
///
/// All fixtures inject temp homes/roots/vaults — no live user state, no
/// Keychain, no signing (glyphs never decrypt).
@MainActor
@Suite("WorkshopModel Glyphs")
struct WorkshopModelGlyphsTests {
    /// Seeds a `.sharibako` under `root` naming `scope`, returns the project dir.
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

    /// Seeds a malformed `.sharibako` (absolute `materialize_to` escapes the
    /// marker directory → `markerMalformed`), which the scan reports as a
    /// failure rather than a marker.
    private static func seedMalformedMarker(under root: URL, named dirName: String) throws {
        let projectDir = root.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try "scope: legit-scope\nmaterialize_to: /etc/passwd\n".write(
            to: projectDir.appendingPathComponent(".sharibako"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// A fresh temp scan root, cleaned up by the caller's `defer`.
    private static func makeRoot(near vault: URL) throws -> URL {
        let root = vault.deletingLastPathComponent().appendingPathComponent(
            "roots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - glyphState

    @Test("glyphState is .liveHere when a marker for the scope is in the scan roots")
    func glyphStateLiveHere() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let root = try Self.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try Self.seedMarker(scope: "kanyo-dev", under: root, named: "kanyo")

            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.scanRoots = [root]
            await model.performLaunchScan()
            #expect(model.glyphState(forScope: "kanyo-dev") == .liveHere)
        }
    }

    @Test("glyphState is .liveElsewhere when the scope has no marker in the roots")
    func glyphStateLiveElsewhere() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let root = try Self.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            // No marker seeded — the scan finds nothing for this scope.

            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.scanRoots = [root]
            await model.performLaunchScan()
            #expect(model.scanReport != nil)
            #expect(model.glyphState(forScope: "kanyo-dev") == .liveElsewhere)
        }
    }

    @Test("glyphState is .liveElsewhere on a cold cache (no scan yet)")
    func glyphStateColdCache() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            // No scan has run — the honest pre-scan answer is "elsewhere".
            #expect(model.scanReport == nil)
            #expect(model.glyphState(forScope: "kanyo-dev") == .liveElsewhere)
        }
    }

    // MARK: - Unlinked markers

    @Test("unlinkedMarkers surfaces an orphan (marker → nonexistent scope), not a valid marker")
    func unlinkedMarkersOrphan() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            // One real vault scope with a valid marker; one marker pointing at a
            // scope the vault does not have.
            try WorkshopTestSupport.writeScope("real-scope", type: .projectDev, in: vault)
            let root = try Self.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try Self.seedMarker(scope: "real-scope", under: root, named: "real")
            _ = try Self.seedMarker(scope: "ghost-scope", under: root, named: "ghost")

            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.scanRoots = [root]
            await model.performLaunchScan()

            let unlinked = model.unlinkedMarkers
            #expect(unlinked.count == 1)
            guard case .orphaned(let scope, _) = unlinked.first else {
                Issue.record("Expected an orphaned marker, got \(String(describing: unlinked.first))")
                return
            }
            #expect(scope == "ghost-scope")
            // The valid marker's scope stays a normal live-here scope, not unlinked.
            #expect(model.glyphState(forScope: "real-scope") == .liveHere)
        }
    }

    @Test("unlinkedMarkers surfaces a malformed marker as a failure")
    func unlinkedMarkersFailure() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let root = try Self.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            try Self.seedMalformedMarker(under: root, named: "broken")

            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.scanRoots = [root]
            await model.performLaunchScan()

            let unlinked = model.unlinkedMarkers
            #expect(unlinked.count == 1)
            guard case .failed(_, let reason) = unlinked.first else {
                Issue.record("Expected a failed marker, got \(String(describing: unlinked.first))")
                return
            }
            #expect(!reason.isEmpty)
        }
    }

    @Test("unlinkedMarkers is empty on a cold cache")
    func unlinkedMarkersColdCache() throws {
        try WorkshopTestSupport.withTempVault { vault in
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            #expect(model.scanReport == nil)
            #expect(model.unlinkedMarkers.isEmpty)
        }
    }

    // MARK: - Pure glyph/marker presentation mappings

    @Test("GlyphState carries a shape-distinct symbol and a naming tooltip per state")
    func glyphStatePresentation() {
        #expect(WorkshopModel.GlyphState.liveHere.symbolName != WorkshopModel.GlyphState.liveElsewhere.symbolName)
        #expect(!WorkshopModel.GlyphState.liveHere.helpText.isEmpty)
        #expect(!WorkshopModel.GlyphState.liveElsewhere.helpText.isEmpty)
    }

    @Test("UnlinkedMarker exposes title, path, id, symbol, and help for both cases")
    func unlinkedMarkerPresentation() {
        let markerURL = URL(fileURLWithPath: "/tmp/proj/.sharibako")
        let orphan = WorkshopModel.UnlinkedMarker.orphaned(scope: "ghost", markerURL: markerURL)
        #expect(orphan.title == "ghost")
        #expect(orphan.markerPath == markerURL.path)
        #expect(orphan.id == "orphaned:\(markerURL.path)")
        #expect(!orphan.symbolName.isEmpty)
        #expect(orphan.helpText.contains("ghost"))

        let failure = WorkshopModel.UnlinkedMarker.failed(markerURL: markerURL, reason: "bad yaml")
        #expect(failure.title == "Malformed marker")
        #expect(failure.markerPath == markerURL.path)
        #expect(failure.id == "failed:\(markerURL.path)")
        #expect(failure.symbolName != orphan.symbolName)
        #expect(failure.helpText.contains("bad yaml"))
    }
}
