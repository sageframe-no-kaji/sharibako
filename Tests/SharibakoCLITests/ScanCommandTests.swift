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
            let result = try cmd.fetchResult(materializer: materializer)
            #expect(result.markers.isEmpty)
            #expect(result.failures.isEmpty)
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
            let result = try cmd.fetchResult(materializer: materializer)
            let entries = result.markers
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
            let entries = try cmd.fetchResult(materializer: materializer).markers
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

    // MARK: - composeOutput

    @Test("composeOutput reports a placeholder when no markers exist")
    func composeOutputEmpty() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            let emptyDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("sharibako-scan-none-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: emptyDir) }

            let vault = try VaultCore(vaultURL: vaultURL)
            let materializer = Materializer(vaultCore: vault, vaultURL: vaultURL)
            let cmd = try ScanCommand.parse([emptyDir.path])
            let result = try cmd.fetchResult(materializer: materializer)
            let output = try cmd.composeOutput(
                result: result, renderer: OutputRenderer(json: false, color: false))
            #expect(output == "No .sharibako markers found.")
        }
    }

    @Test("composeOutput renders the SCOPE/MARKER/TARGET table for found markers")
    func composeOutputTable() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            let rootDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("sharibako-scan-table-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: rootDir) }

            let vault = try VaultCore(vaultURL: vaultURL)
            let materializer = Materializer(vaultCore: vault, vaultURL: vaultURL)
            let marker = ScopeMarker(scope: "table-proj", materializeTo: nil, markerURL: .init(fileURLWithPath: "/"))
            try materializer.writeMarker(marker, at: rootDir.appendingPathComponent(".sharibako"))

            let cmd = try ScanCommand.parse([rootDir.path])
            let result = try cmd.fetchResult(materializer: materializer)
            let output = try cmd.composeOutput(
                result: result, renderer: OutputRenderer(json: false, color: false))
            #expect(output.contains("SCOPE"))
            #expect(output.contains("table-proj"))
            #expect(output.contains(".sharibako"))
            #expect(output.contains(".env"))
        }
    }

    @Test("composeOutput --json emits decodable entries for found markers")
    func composeOutputJSON() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            let rootDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("sharibako-scan-json-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: rootDir) }

            let vault = try VaultCore(vaultURL: vaultURL)
            let materializer = Materializer(vaultCore: vault, vaultURL: vaultURL)
            let marker = ScopeMarker(scope: "json-proj", materializeTo: nil, markerURL: .init(fileURLWithPath: "/"))
            try materializer.writeMarker(marker, at: rootDir.appendingPathComponent(".sharibako"))

            let cmd = try ScanCommand.parse([rootDir.path, "--json"])
            let result = try cmd.fetchResult(materializer: materializer)
            let output = try cmd.composeOutput(
                result: result, renderer: OutputRenderer(json: true, color: false))
            let decoded = try JSONDecoder().decode(ScanJSONResult.self, from: Data(output.utf8))
            #expect(decoded.markers.map(\.scope) == ["json-proj"])
            #expect(decoded.failures.isEmpty)
        }
    }

    // MARK: - Skip-and-report (ho-04.11)

    @Test("one hostile marker is skipped and reported; healthy markers still scan")
    func scanSkipsAndReportsHostileMarker() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            let rootDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("sharibako-scan-hostile-\(UUID().uuidString)")
            let goodDir = rootDir.appendingPathComponent("good-proj")
            let badDir = rootDir.appendingPathComponent("cloned-repo")
            try FileManager.default.createDirectory(at: goodDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: rootDir) }

            let vault = try VaultCore(vaultURL: vaultURL)
            let materializer = Materializer(vaultCore: vault, vaultURL: vaultURL)
            let good = ScopeMarker(scope: "good-proj", materializeTo: nil, markerURL: .init(fileURLWithPath: "/"))
            try materializer.writeMarker(good, at: goodDir.appendingPathComponent(".sharibako"))
            // Hostile marker: escaping materialize_to, rejected at load since ho-04.9.
            try "scope: evil\nmaterialize_to: ../../outside/.env\n".write(
                to: badDir.appendingPathComponent(".sharibako"), atomically: true, encoding: .utf8
            )

            let cmd = try ScanCommand.parse([rootDir.path])
            let result = try cmd.fetchResult(materializer: materializer)
            #expect(result.markers.map(\.scope) == ["good-proj"])
            #expect(result.failures.count == 1)
            #expect(result.failures.first?.path.contains("cloned-repo") == true)
        }
    }

    @Test("status for a healthy scope survives a hostile marker in the same scan root")
    func statusSurvivesHostileMarker() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            try CLITestSupport.writeScope("good-proj", type: .projectDev, in: vaultURL)
            let rootDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("sharibako-status-hostile-\(UUID().uuidString)")
            let goodDir = rootDir.appendingPathComponent("good-proj")
            let badDir = rootDir.appendingPathComponent("cloned-repo")
            try FileManager.default.createDirectory(at: goodDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: rootDir) }

            let vault = try VaultCore(vaultURL: vaultURL)
            let materializer = Materializer(vaultCore: vault, vaultURL: vaultURL)
            let good = ScopeMarker(scope: "good-proj", materializeTo: nil, markerURL: .init(fileURLWithPath: "/"))
            try materializer.writeMarker(good, at: goodDir.appendingPathComponent(".sharibako"))
            try "scope: ../evil\n".write(
                to: badDir.appendingPathComponent(".sharibako"), atomically: true, encoding: .utf8
            )

            // Pre-ho-04.11 this threw markerMalformed out of the scan walk.
            let state = try materializer.status(scopeID: "good-proj", scanRoots: [rootDir])
            guard case .liveHere = state else {
                Issue.record("expected .liveHere, got \(state)")
                return
            }
        }
    }

    // MARK: - End to end

    @Test("scan runs end-to-end against an ephemeral vault")
    func scanEndToEnd() async throws {
        try await CLITestSupport.withEphemeralVaultAndFileKeyAsync { vaultURL, _ in
            let emptyDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("sharibako-scan-e2e-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: emptyDir) }
            try await CLITestSupport.runCommand(["scan", emptyDir.path, "--vault", vaultURL.path])
        }
    }
}
