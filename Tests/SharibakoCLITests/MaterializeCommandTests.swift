import Foundation
import Testing

@testable import SharibakoCLI
@testable import SharibakoCore

@Suite("MaterializeCommand")
struct MaterializeCommandTests {
    /// Creates a project dir with a `.sharibako` marker and returns both URLs.
    private func makeProject(
        vaultURL: URL, core: VaultCore, scopeID: String
    ) throws -> (projectDir: URL, marker: ScopeMarker) {
        let projectDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mat-proj-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let materializer = Materializer(vaultCore: core, vaultURL: vaultURL)
        let markerURL = projectDir.appendingPathComponent(".sharibako")
        let marker = ScopeMarker(scope: scopeID, materializeTo: nil, markerURL: markerURL)
        try materializer.writeMarker(marker, at: markerURL)
        return (projectDir, try materializer.loadMarker(at: markerURL))
    }

    @Test("writes .env with owned keys when scope is given explicitly")
    func materializeWithExplicitScope() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            let core = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            try core.addSecret("API_KEY", value: "v1", inScope: "s1")

            let (projectDir, _) = try makeProject(vaultURL: vaultURL, core: core, scopeID: "s1")
            defer { try? FileManager.default.removeItem(at: projectDir) }

            var cmd = try MaterializeCommand.parse([
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
                "s1",
            ])
            try cmd._run(cwd: projectDir)

            let envContent = try String(contentsOf: projectDir.appendingPathComponent(".env"), encoding: .utf8)
            #expect(envContent.contains("API_KEY=v1"))
        }
    }

    @Test("resolves scope from cwd when no scope arg is given")
    func materializeWithCwdResolution() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            let core = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            try core.addSecret("SECRET", value: "auto-resolved", inScope: "s1")

            let (projectDir, _) = try makeProject(vaultURL: vaultURL, core: core, scopeID: "s1")
            defer { try? FileManager.default.removeItem(at: projectDir) }

            var cmd = try MaterializeCommand.parse([
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
            ])
            try cmd._run(cwd: projectDir)

            let envContent = try String(contentsOf: projectDir.appendingPathComponent(".env"), encoding: .utf8)
            #expect(envContent.contains("SECRET=auto-resolved"))
        }
    }

    @Test("second materialize reports already up to date without rewriting")
    func materializeUnchanged() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            let core = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            try core.addSecret("API_KEY", value: "v1", inScope: "s1")

            let (projectDir, _) = try makeProject(vaultURL: vaultURL, core: core, scopeID: "s1")
            defer { try? FileManager.default.removeItem(at: projectDir) }

            var cmd = try MaterializeCommand.parse([
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
                "s1",
            ])
            try cmd._run(cwd: projectDir)
            let envPath = projectDir.appendingPathComponent(".env")
            let firstPass = try String(contentsOf: envPath, encoding: .utf8)

            // Second pass: `.unchanged` branch; file bytes identical.
            try cmd._run(cwd: projectDir)
            let secondPass = try String(contentsOf: envPath, encoding: .utf8)
            #expect(secondPass == firstPass)
        }
    }

    @Test("drift without --force renders the diff and throws materializeDiffPending")
    func materializeDriftPending() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            let core = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            try core.addSecret("K1", value: "v1", inScope: "s1")
            try core.addSecret("K2", value: "v2", inScope: "s1")

            let (projectDir, _) = try makeProject(vaultURL: vaultURL, core: core, scopeID: "s1")
            defer { try? FileManager.default.removeItem(at: projectDir) }

            var cmd = try MaterializeCommand.parse([
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
                "s1",
            ])
            try cmd._run(cwd: projectDir)

            // Introduce both drift shapes: K1 differs, K2 vanishes from the file.
            let envPath = projectDir.appendingPathComponent(".env")
            let drifted = try String(contentsOf: envPath, encoding: .utf8)
                .replacingOccurrences(of: "K1=v1", with: "K1=tampered")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.hasPrefix("K2=") }
                .joined(separator: "\n")
            try drifted.write(to: envPath, atomically: true, encoding: .utf8)

            #expect(throws: CLIError.materializeDiffPending) {
                try cmd._run(cwd: projectDir)
            }
            // Without --force the drifted file is left alone.
            let afterDiff = try String(contentsOf: envPath, encoding: .utf8)
            #expect(afterDiff.contains("K1=tampered"))
        }
    }

    @Test("--force overwrites drifted owned lines with vault values")
    func materializeForceOverwritesDrift() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try CLITestSupport.writeScope("s1", in: vaultURL)
            let core = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            try core.addSecret("K1", value: "v1", inScope: "s1")

            let (projectDir, _) = try makeProject(vaultURL: vaultURL, core: core, scopeID: "s1")
            defer { try? FileManager.default.removeItem(at: projectDir) }

            var cmd = try MaterializeCommand.parse([
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
                "s1",
            ])
            try cmd._run(cwd: projectDir)

            let envPath = projectDir.appendingPathComponent(".env")
            let drifted = try String(contentsOf: envPath, encoding: .utf8)
                .replacingOccurrences(of: "K1=v1", with: "K1=tampered")
            try drifted.write(to: envPath, atomically: true, encoding: .utf8)

            var forceCmd = try MaterializeCommand.parse([
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
                "--force",
                "s1",
            ])
            try forceCmd._run(cwd: projectDir)

            let restored = try String(contentsOf: envPath, encoding: .utf8)
            #expect(restored.contains("K1=v1"))
        }
    }

    @Test("_run throws markerNotFound when cwd has no .sharibako and no scope given")
    func materializeNoMarkerNorScope() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            let emptyDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("empty-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: emptyDir) }

            var cmd = try MaterializeCommand.parse([
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
            ])
            #expect(throws: (any Error).self) {
                try cmd._run(cwd: emptyDir)
            }
        }
    }
}
