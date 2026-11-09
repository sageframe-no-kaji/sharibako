import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// ho-06.10 gate: the sidebar's way in for an arbitrary tree.
@MainActor
@Suite("WorkshopModel scan-folder hint")
struct WorkshopModelScanHintTests {
    @Test("the hint names the situation when nothing waits, and is nil when folders wait")
    func hintStates() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let home = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: home) }
            let model = FirstRunTestSupport.openVaultModel(vault: vault, home: home)

            #expect(model.notProtectedHint == "No folders are scanned yet.")

            let root = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            model.scanRoots = [root]
            #expect(model.notProtectedHint == "Nothing waiting to be protected under your scan folders.")

            try ProjectsTestSupport.writeEnv("API_KEY=k-0000\n", in: root.appendingPathComponent("p"))
            await model.rescan()
            #expect(model.candidates.count == 1)
            #expect(model.notProtectedHint == nil)
        }
    }

    @Test("addScanFolderAndRescan registers the folder and finds its projects")
    func addAndRescan() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let home = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: home) }
            let tree = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: tree) }
            try ProjectsTestSupport.writeEnv("TOKEN=t-0000\n", in: tree.appendingPathComponent("a/b/proj"))
            let model = FirstRunTestSupport.openVaultModel(vault: vault, home: home)

            await model.addScanFolderAndRescan(tree)

            #expect(model.scanRoots.map { $0.standardizedFileURL.path } == [tree.standardizedFileURL.path])
            #expect(model.candidates.count == 1)
            #expect(model.notProtectedHint == nil)

            await model.addScanFolderAndRescan(tree)  // already listed: no second root, announced
            #expect(model.scanRoots.count == 1)
            #expect(model.statusMessage?.contains("already scanned") == true)
        }
    }
}
