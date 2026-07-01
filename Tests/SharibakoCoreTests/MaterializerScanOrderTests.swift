import Foundation
import Testing

@testable import SharibakoCore

/// Ordering guarantees for `Materializer.scan`.
///
/// Breadth-first across roots, alphabetical within a depth. Split from
/// `MaterializerWriteTests` so each test struct stays under the type-body-length
/// ceiling.
@Suite("Materializer Scan Order")
struct MaterializerScanOrderTests {
    @Test("scan orders markers at the same depth alphabetically")
    func scanAlphabeticalWithinDepth() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let bento = project.appendingPathComponent("bento")
                let alpha = project.appendingPathComponent("alpha")
                try FileManager.default.createDirectory(at: bento, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
                try "scope: bento\n"
                    .write(to: bento.appendingPathComponent(".sharibako"), atomically: true, encoding: .utf8)
                try "scope: alpha\n"
                    .write(to: alpha.appendingPathComponent(".sharibako"), atomically: true, encoding: .utf8)
                let core = try VaultCore(vaultURL: vault)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let markers = try mat.scan(roots: [project])
                #expect(markers.map(\.scope) == ["alpha", "bento"])
            }
        }
    }

    @Test("scan orders markers breadth-first: shallower depth first, alphabetical within a depth")
    func scanOrdersBreadthFirst() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let deep = project.appendingPathComponent("apps/backend")
                try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
                try "scope: backend\n"
                    .write(to: deep.appendingPathComponent(".sharibako"), atomically: true, encoding: .utf8)
                try "scope: root\n"
                    .write(to: project.appendingPathComponent(".sharibako"), atomically: true, encoding: .utf8)
                let core = try VaultCore(vaultURL: vault)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let markers = try mat.scan(roots: [project])
                #expect(markers.map(\.scope) == ["root", "backend"])
            }
        }
    }
}
