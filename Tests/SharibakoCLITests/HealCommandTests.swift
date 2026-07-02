import Foundation
import Testing

@testable import SharibakoCLI
@testable import SharibakoCore

@Suite("HealCommand")
struct HealCommandTests {
    // MARK: - buildHealResult

    @Test("buildHealResult maps match drift correctly")
    func buildMatchDrift() throws {
        let report = DriftReport(
            scopeID: "test",
            path: URL(fileURLWithPath: "/tmp/test/.env"),
            owned: [.match(key: "API_KEY")],
            parseWarnings: []
        )
        let cmd = try HealCommand.parse([])
        let result = cmd.buildHealResult(from: report)
        #expect(result.scopeID == "test")
        #expect(result.owned.count == 1)
        #expect(result.owned[0].key == "API_KEY")
        #expect(result.owned[0].status == "match")
        #expect(result.owned[0].vaultSha256 == nil)
        #expect(result.owned[0].fileSha256 == nil)
    }

    @Test("buildHealResult maps fileMissing drift correctly")
    func buildFileMissingDrift() throws {
        let report = DriftReport(
            scopeID: "test",
            path: URL(fileURLWithPath: "/tmp/.env"),
            owned: [.fileMissing(key: "SECRET")],
            parseWarnings: []
        )
        let cmd = try HealCommand.parse([])
        let result = cmd.buildHealResult(from: report)
        #expect(result.owned[0].status == "fileMissing")
        #expect(result.owned[0].key == "SECRET")
    }

    @Test("buildHealResult maps fileValueDiffers drift with SHAs")
    func buildFileValueDiffersDrift() throws {
        let report = DriftReport(
            scopeID: "test",
            path: URL(fileURLWithPath: "/tmp/.env"),
            owned: [.fileValueDiffers(key: "TOKEN", vaultSha256: "abc", fileSha256: "def")],
            parseWarnings: []
        )
        let cmd = try HealCommand.parse([])
        let result = cmd.buildHealResult(from: report)
        #expect(result.owned[0].status == "fileValueDiffers")
        #expect(result.owned[0].vaultSha256 == "abc")
        #expect(result.owned[0].fileSha256 == "def")
    }

    // MARK: - JSON structure

    @Test("heal --json emits a valid HealResult structure")
    func jsonStructure() throws {
        let report = DriftReport(
            scopeID: "myapp",
            path: URL(fileURLWithPath: "/projects/myapp/.env"),
            owned: [
                .match(key: "PORT"),
                .fileMissing(key: "SECRET_KEY"),
            ],
            parseWarnings: []
        )
        let cmd = try HealCommand.parse([])
        let result = cmd.buildHealResult(from: report)

        let renderer = OutputRenderer(json: true, color: false)
        let json = try renderer.encodeJSON(result)
        let decoded = try JSONDecoder().decode(HealResult.self, from: Data(json.utf8))
        #expect(decoded.scopeID == "myapp")
        #expect(decoded.owned.count == 2)
        #expect(decoded.owned.first?.key == "PORT")
        #expect(decoded.owned.first?.status == "match")
        #expect(decoded.owned.last?.status == "fileMissing")
    }

    // MARK: - Mixed drift integration (real age)

    @Test("heal reports mixed match/differs/missing from a real vault")
    func healMixedDriftReport() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            let scopeID = "heal-test"
            try CLITestSupport.writeScope(scopeID, type: .projectDev, in: vaultURL)
            let core = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)

            // Add two secrets.
            try core.addSecret("MATCH_KEY", value: "correct-value", inScope: scopeID)
            try core.addSecret("DIFFERS_KEY", value: "vault-value", inScope: scopeID)
            // MISSING_KEY intentionally not added to vault but referenced below.
            // Actually we'll only add MATCH_KEY and DIFFERS_KEY — file can be missing one.

            // Create a .env file with MATCH_KEY correct, DIFFERS_KEY wrong, MISSING_KEY absent.
            let projectDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("heal-proj-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: projectDir) }

            let envFile = projectDir.appendingPathComponent(".env")
            let envContent = "MATCH_KEY=correct-value\nDIFFERS_KEY=wrong-value\n"
            try envContent.write(to: envFile, atomically: true, encoding: .utf8)

            let markerURL = projectDir.appendingPathComponent(".sharibako")
            let marker = ScopeMarker(scope: scopeID, materializeTo: nil, markerURL: markerURL)
            let materializer = Materializer(vaultCore: core, vaultURL: vaultURL)
            try materializer.writeMarker(marker, at: markerURL)

            // Heal needs the marker loaded from disk.
            let loadedMarker = try materializer.loadMarker(at: markerURL)
            let report = try materializer.heal(marker: loadedMarker)

            #expect(report.scopeID == scopeID)
            #expect(report.owned.count == 2)

            let matchEntry = report.owned.first { entry in
                if case .match(let keyName) = entry { return keyName == "MATCH_KEY" }
                return false
            }
            #expect(matchEntry != nil)

            let differEntry = report.owned.first { entry in
                if case .fileValueDiffers(let keyName, _, _) = entry { return keyName == "DIFFERS_KEY" }
                return false
            }
            #expect(differEntry != nil)
        }
    }
}
