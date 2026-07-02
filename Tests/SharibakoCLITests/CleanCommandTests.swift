import Foundation
import Testing

@testable import SharibakoCLI
@testable import SharibakoCore

@Suite("CleanCommand")
struct CleanCommandTests {
    private func makeProjectWithEnv(
        vaultURL: URL, keyURL: URL, scopeID: String
    ) throws -> URL {
        let core = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
        try core.addSecret("K", value: "v", inScope: scopeID)
        let projectDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clean-proj-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let materializer = Materializer(vaultCore: core, vaultURL: vaultURL)
        let markerURL = projectDir.appendingPathComponent(".sharibako")
        let marker = ScopeMarker(scope: scopeID, materializeTo: nil, markerURL: markerURL)
        try materializer.writeMarker(marker, at: markerURL)
        let loadedMarker = try materializer.loadMarker(at: markerURL)
        _ = try materializer.materialize(marker: loadedMarker)
        return projectDir
    }

    @Test("cleans owned lines when --yes is supplied")
    func cleanWithYesFlag() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            let projectDir = try makeProjectWithEnv(vaultURL: vaultURL, keyURL: keyURL, scopeID: "s1")
            defer { try? FileManager.default.removeItem(at: projectDir) }

            var cmd = try CleanCommand.parse([
                "--vault", vaultURL.path,
                "--yes",
            ])
            try cmd._run(cwd: projectDir)

            let envPath = projectDir.appendingPathComponent(".env")
            #expect(!FileManager.default.fileExists(atPath: envPath.path))
        }
    }

    @Test("confirmation prompt: 'y' proceeds with clean")
    func cleanConfirmationYes() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            let projectDir = try makeProjectWithEnv(vaultURL: vaultURL, keyURL: keyURL, scopeID: "s1")
            defer { try? FileManager.default.removeItem(at: projectDir) }

            var cmd = try CleanCommand.parse([
                "--vault", vaultURL.path,
            ])
            try cmd._run(cwd: projectDir) { "y" }

            let envPath = projectDir.appendingPathComponent(".env")
            #expect(!FileManager.default.fileExists(atPath: envPath.path))
        }
    }

    @Test("confirmation prompt: 'n' aborts without changing .env")
    func cleanConfirmationNo() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            let projectDir = try makeProjectWithEnv(vaultURL: vaultURL, keyURL: keyURL, scopeID: "s1")
            defer { try? FileManager.default.removeItem(at: projectDir) }

            var cmd = try CleanCommand.parse([
                "--vault", vaultURL.path,
            ])
            try cmd._run(cwd: projectDir) { "n" }

            let envPath = projectDir.appendingPathComponent(".env")
            #expect(FileManager.default.fileExists(atPath: envPath.path))
            let content = try String(contentsOf: envPath, encoding: .utf8)
            #expect(content.contains("K=v"))
        }
    }

    @Test("clean reports fileMissing when no .env exists")
    func cleanFileMissing() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            let core = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            try core.addSecret("K", value: "v", inScope: "s1")

            let projectDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("clean-empty-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: projectDir) }

            let materializer = Materializer(vaultCore: core, vaultURL: vaultURL)
            let markerURL = projectDir.appendingPathComponent(".sharibako")
            let marker = ScopeMarker(scope: "s1", materializeTo: nil, markerURL: markerURL)
            try materializer.writeMarker(marker, at: markerURL)

            var cmd = try CleanCommand.parse([
                "--vault", vaultURL.path,
                "--yes",
            ])
            // Should succeed with a "Nothing to clean" message; no throw.
            try cmd._run(cwd: projectDir)
        }
    }
}
