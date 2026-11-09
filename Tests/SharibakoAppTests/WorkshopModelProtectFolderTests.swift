import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// Choosing a folder (`WorkshopModel+Ingest.swift`): protecting a hand-picked
/// folder outside the scan roots registers it as a root (ho-06.9 gate fix, so
/// it survives the next launch) and selects it; `beginIngest(directory:)`
/// selects a folder's row — project, Problem, or not yet protected — with no
/// sheet (ho-06.10 Decision 6); and the first-run finish page's folder walk.
@MainActor
@Suite("WorkshopModel Protect a folder")
struct WorkshopModelProtectFolderTests {
    @Test("a folder outside the roots is registered as a root and selected")
    func protectFolderOutsideRoots() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let root = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            let elsewhere = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: elsewhere) }
            let side = elsewhere.appendingPathComponent("side-project")
            try ProjectsTestSupport.writeEnv("SIDE_API_KEY=side-0000\nLOG_LEVEL=debug\n", in: side)

            let home = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: home) }
            let model = FirstRunTestSupport.openVaultModel(vault: vault, home: home)
            try WorkshopConfig.persistScanRoot(root, configURL: model.configURL)
            model.scanRoots = [root]

            await model.protectFolder(side)

            let roots = model.scanRoots.map { $0.standardizedFileURL.path }
            #expect(roots.contains(side.standardizedFileURL.path))
            #expect(
                WorkshopConfig.loadScanRoots(configURL: model.configURL)
                    .map { $0.standardizedFileURL.path }
                    .contains(side.standardizedFileURL.path))
            let candidate = try #require(
                model.candidates.first { $0.standardizedFileURL.path == side.standardizedFileURL.path })
            #expect(model.selection == .candidate(directory: candidate))
            #expect(model.selectedEntry != nil)
            #expect(model.activity == nil)
        }
    }

    @Test("a folder already under a root is not registered again")
    func protectFolderInsideRoots() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let root = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            let inside = root.appendingPathComponent("inside")
            try ProjectsTestSupport.writeEnv("TOKEN=t-0000\n", in: inside)

            let home = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: home) }
            let model = FirstRunTestSupport.openVaultModel(vault: vault, home: home)
            try WorkshopConfig.persistScanRoot(root, configURL: model.configURL)
            model.scanRoots = [root]
            await model.protectFolder(inside)

            #expect(model.scanRoots.count == 1)
            #expect(model.selection == .candidate(directory: inside.standardizedFileURL))
        }
    }

    @Test("a folder whose root cannot be saved reports the failure and selects nothing")
    func protectFolderPersistFailure() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let elsewhere = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: elsewhere) }
            // The config path's parent is a file, so the root cannot be written.
            let home = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: home) }
            let model = FirstRunTestSupport.openVaultModel(vault: vault, home: home)
            let configParent = model.configURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: configParent.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "not a directory".write(to: configParent, atomically: true, encoding: .utf8)

            await model.protectFolder(elsewhere)

            #expect(model.errorMessage != nil)
            #expect(model.selection == nil)
            #expect(model.activity == nil)
        }
    }

    @Test("beginIngest selects a known project's row and a Problem folder's row by their claim files")
    func beginIngestSelectsByClaimFile() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("falcon", type: .other, in: vault)
            let root = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            let falcon = try ProjectsTestSupport.seedMarker(scope: "falcon", under: root, named: "falcon")
            let ghost = try ProjectsTestSupport.seedMarker(scope: "ghost", under: root, named: "ghost")
            let model = ProjectsTestSupport.model(vault: vault)
            model.scanRoots = [root]
            await model.performLaunchScan()

            model.beginIngest(directory: falcon)
            #expect(model.selection == .project(scopeID: "falcon"))

            model.beginIngest(directory: URL(fileURLWithPath: ghost.path + "/"))
            let orphan = try #require(model.unlinkedMarkers.first)
            #expect(model.selection == .problem(markerPath: orphan.markerPath))
        }
    }

    @Test("beginIngest is a no-op with no vault open")
    func beginIngestNoVault() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharibako-begin-\(UUID().uuidString)")
        let model = FirstRunTestSupport.noVaultModel(home: home)

        model.beginIngest(directory: URL(fileURLWithPath: "/tmp/acme"))

        #expect(model.selection == nil)
    }

    @Test("findFirstRunIngestCandidates returns .env-bearing directories under root")
    func findFirstRunIngestCandidatesFindsDirectories() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let root = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            try ProjectsTestSupport.writeEnv("API_KEY=sk-live\n", in: root.appendingPathComponent("bento"))
            let model = ProjectsTestSupport.model(vault: vault)

            let found = await model.findFirstRunIngestCandidates(under: root)

            #expect(found.map(\.lastPathComponent) == ["bento"])
        }
    }
}
