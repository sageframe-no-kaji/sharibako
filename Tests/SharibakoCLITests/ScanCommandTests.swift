import Foundation
import Testing

@testable import SharibakoCLI
@testable import SharibakoCore

@Suite("ScanCommand")
struct ScanCommandTests {
    // MARK: - fetchEntries

    @Test("fetchEntries returns empty array when no markers exist")
    func fetchEntriesNoMarkers() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            let emptyDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("sharibako-scan-empty-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: emptyDir) }

            let vault = try VaultCore(vaultURL: vaultURL)
            let materializer = Materializer(vaultCore: vault, vaultURL: vaultURL)
            let cmd = try ScanCommand.parse([emptyDir.path])
            let entries = try cmd.fetchEntries(materializer: materializer)
            #expect(entries.isEmpty)
        }
    }

    @Test("fetchEntries finds a marker in a subdirectory")
    func fetchEntriesFindsNestedMarker() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            try CLITestSupport.writeScope("my-proj", type: .projectDev, in: vaultURL)

            let rootDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("sharibako-scan-root-\(UUID().uuidString)")
            let projDir = rootDir.appendingPathComponent("projects").appendingPathComponent("my-proj")
            try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: rootDir) }

            let marker = ScopeMarker(scope: "my-proj", materializeTo: nil, markerURL: .init(fileURLWithPath: "/"))
            let markerURL = projDir.appendingPathComponent(".sharibako")
            let vault = try VaultCore(vaultURL: vaultURL)
            let materializer = Materializer(vaultCore: vault, vaultURL: vaultURL)
            try materializer.writeMarker(marker, at: markerURL)

            let cmd = try ScanCommand.parse([rootDir.path])
            let entries = try cmd.fetchEntries(materializer: materializer)
            #expect(entries.count == 1)
            #expect(entries.first?.scope == "my-proj")
            // Compare the filename only: macOS enumerators resolve /var/folders to
            // /private/var/folders while URL construction doesn't, making full-path
            // comparison fragile.
            #expect(URL(fileURLWithPath: entries.first?.path ?? "").lastPathComponent == ".sharibako")
        }
    }

    @Test("fetchEntries finds multiple markers at different depths")
    func fetchEntriesMultipleMarkers() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            try CLITestSupport.writeScope("proj-a", type: .projectDev, in: vaultURL)
            try CLITestSupport.writeScope("proj-b", type: .projectDev, in: vaultURL)

            let rootDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("sharibako-scan-multi-\(UUID().uuidString)")
            let dirA = rootDir.appendingPathComponent("proj-a")
            let dirB = rootDir.appendingPathComponent("sub").appendingPathComponent("proj-b")
            try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: rootDir) }

            let vault = try VaultCore(vaultURL: vaultURL)
            let materializer = Materializer(vaultCore: vault, vaultURL: vaultURL)
            let markerA = ScopeMarker(scope: "proj-a", materializeTo: nil, markerURL: .init(fileURLWithPath: "/"))
            let markerB = ScopeMarker(scope: "proj-b", materializeTo: nil, markerURL: .init(fileURLWithPath: "/"))
            try materializer.writeMarker(markerA, at: dirA.appendingPathComponent(".sharibako"))
            try materializer.writeMarker(markerB, at: dirB.appendingPathComponent(".sharibako"))

            let cmd = try ScanCommand.parse([rootDir.path])
            let entries = try cmd.fetchEntries(materializer: materializer)
            #expect(entries.count == 2)
            #expect(entries.map(\.scope).sorted() == ["proj-a", "proj-b"])
        }
    }

    // MARK: - JSON structure

    @Test("scan --json emits a valid JSON array with path/scope/target fields")
    func jsonStructure() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { _, _ in
            let entries = [
                ScanEntry(path: "/proj/.sharibako", scope: "proj", target: "/proj/.env")
            ]
            let renderer = OutputRenderer(json: true, color: false)
            let json = try renderer.encodeJSON(entries)
            let decoded = try JSONDecoder().decode([ScanEntry].self, from: Data(json.utf8))
            #expect(decoded.count == 1)
            #expect(decoded.first?.scope == "proj")
            #expect(decoded.first?.path == "/proj/.sharibako")
            #expect(decoded.first?.target == "/proj/.env")
        }
    }

    @Test("scan --json emits empty array when no markers found")
    func jsonEmpty() throws {
        let entries: [ScanEntry] = []
        let renderer = OutputRenderer(json: true, color: false)
        let json = try renderer.encodeJSON(entries)
        let decoded = try JSONDecoder().decode([ScanEntry].self, from: Data(json.utf8))
        #expect(decoded.isEmpty)
    }
}
