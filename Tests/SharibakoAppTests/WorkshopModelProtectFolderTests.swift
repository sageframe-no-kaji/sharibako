import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// ho-06.9 gate fix: protecting a hand-picked folder outside the scan roots
/// registers it as a root (so it survives the next launch) and opens the
/// Protect sheet for it.
@MainActor
@Suite("WorkshopModel Protect a folder")
struct WorkshopModelProtectFolderTests {
    @Test("a folder outside the roots is registered as a root and its Protect sheet opens")
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
            #expect(model.ingest.session?.directory.standardizedFileURL.path == side.standardizedFileURL.path)
            #expect(model.candidates.map { $0.standardizedFileURL.path }.contains(side.standardizedFileURL.path))
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
            #expect(model.ingest.session?.directory.standardizedFileURL.path == inside.standardizedFileURL.path)
        }
    }
}
