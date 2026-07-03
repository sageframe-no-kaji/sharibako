import Foundation
import Testing

@testable import SharibakoCLI
@testable import SharibakoCore

@Suite("UpdateCommand")
struct UpdateCommandTests {
    @Test("pushes hand-edited .env values back into the vault")
    func updateHappyPath() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            let core = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            try core.addSecret("API_KEY", value: "original", inScope: "s1")

            let projectDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("upd-proj-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: projectDir) }

            let materializer = Materializer(vaultCore: core, vaultURL: vaultURL)
            let markerURL = projectDir.appendingPathComponent(".sharibako")
            let marker = ScopeMarker(scope: "s1", materializeTo: nil, markerURL: markerURL)
            try materializer.writeMarker(marker, at: markerURL)
            let loadedMarker = try materializer.loadMarker(at: markerURL)

            // Materialize first to create the .env.
            _ = try materializer.materialize(marker: loadedMarker)

            // Hand-edit the .env.
            let envPath = projectDir.appendingPathComponent(".env")
            var content = try String(contentsOf: envPath, encoding: .utf8)
            content = content.replacingOccurrences(of: "API_KEY=original", with: "API_KEY=updated")
            try content.write(to: envPath, atomically: true, encoding: .utf8)

            // Run update command.
            var cmd = try UpdateCommand.parse([
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
            ])
            try cmd._run(cwd: projectDir)

            let newVault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            #expect((try? newVault.getValue("API_KEY", inScope: "s1")) == "updated")
        }
    }

    @Test("_run is a no-op when vault and file already agree")
    func updateNoChanges() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            let core = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            try core.addSecret("K", value: "same", inScope: "s1")

            let projectDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("upd-proj-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: projectDir) }

            let materializer = Materializer(vaultCore: core, vaultURL: vaultURL)
            let markerURL = projectDir.appendingPathComponent(".sharibako")
            let marker = ScopeMarker(scope: "s1", materializeTo: nil, markerURL: markerURL)
            try materializer.writeMarker(marker, at: markerURL)
            let loadedMarker = try materializer.loadMarker(at: markerURL)
            _ = try materializer.materialize(marker: loadedMarker)

            var cmd = try UpdateCommand.parse([
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
            ])
            // Should succeed without changing the vault.
            try cmd._run(cwd: projectDir)
            let newVault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            #expect((try? newVault.getValue("K", inScope: "s1")) == "same")
        }
    }

    @Test("_run throws updateFileMissing when the target .env does not exist")
    func updateFileMissing() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            let core = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            try core.addSecret("K", value: "v", inScope: "s1")

            let projectDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("upd-missing-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: projectDir) }

            // Marker without a materialized .env.
            let materializer = Materializer(vaultCore: core, vaultURL: vaultURL)
            let markerURL = projectDir.appendingPathComponent(".sharibako")
            let marker = ScopeMarker(scope: "s1", materializeTo: nil, markerURL: markerURL)
            try materializer.writeMarker(marker, at: markerURL)

            var cmd = try UpdateCommand.parse([
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
            ])
            #expect(throws: CLIError.updateFileMissing) {
                try cmd._run(cwd: projectDir)
            }
        }
    }

    @Test("malformed .env lines surface as warnings while owned keys still update")
    func updateEmitsWarnings() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            let core = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            try core.addSecret("API_KEY", value: "original", inScope: "s1")

            let projectDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("upd-warn-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: projectDir) }

            let materializer = Materializer(vaultCore: core, vaultURL: vaultURL)
            let markerURL = projectDir.appendingPathComponent(".sharibako")
            let marker = ScopeMarker(scope: "s1", materializeTo: nil, markerURL: markerURL)
            try materializer.writeMarker(marker, at: markerURL)
            let loadedMarker = try materializer.loadMarker(at: markerURL)
            _ = try materializer.materialize(marker: loadedMarker)

            // Hand-edit: change the owned value AND add a malformed line.
            let envPath = projectDir.appendingPathComponent(".env")
            let content = try String(contentsOf: envPath, encoding: .utf8)
                .replacingOccurrences(of: "API_KEY=original", with: "API_KEY=edited")
            try (content + "123 not a valid line\n").write(
                to: envPath, atomically: true, encoding: .utf8
            )

            var cmd = try UpdateCommand.parse([
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
            ])
            // The malformed line warns (stderr) but does not block the update.
            try cmd._run(cwd: projectDir)

            let newVault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            #expect((try? newVault.getValue("API_KEY", inScope: "s1")) == "edited")
        }
    }
}
