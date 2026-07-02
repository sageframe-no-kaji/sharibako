import Foundation
import Testing

@testable import SharibakoCLI
@testable import SharibakoCore

/// End-to-end round-trip: key file → add → get → materialize → hand-edit → update → get → clean.
///
/// Uses `FileAgeKeyProvider` (via `--age-key`) throughout, bypassing the Keychain.
/// Materializer-triad steps invoke internal command helpers with an explicit cwd
/// so the test does not need to mutate the process's working directory.
@Suite("RoundTripCommandTests")
struct RoundTripCommandTests {
    @Test("full add → get → materialize → update → get → clean flow")
    func roundTripFlow() async throws {
        // ── Setup ──────────────────────────────────────────────────────────────────
        try await CLITestSupport.withEphemeralVaultAndFileKeyAsync { vaultURL, keyURL in
            let scopeID = "kanyo-dev"
            try CLITestSupport.writeScope(scopeID, in: vaultURL)

            // ── Step 1: add via CLI ────────────────────────────────────────────────
            try await CLITestSupport.runCommand([
                "add",
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
                scopeID, "API_KEY", "--value", "sk-live-abc",
            ])

            // ── Step 2: get via CLI internal helper ────────────────────────────────
            var getCmd = try GetCommand.parse([
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
                scopeID, "API_KEY",
            ])
            let gotValue = try getCmd.fetchValue()
            #expect(gotValue == "sk-live-abc")

            // ── Step 3: create project dir + .sharibako marker ─────────────────────
            let projectDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("round-trip-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: projectDir) }

            let core = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            let materializer = Materializer(vaultCore: core, vaultURL: vaultURL)
            let markerURL = projectDir.appendingPathComponent(".sharibako")
            let marker = ScopeMarker(scope: scopeID, materializeTo: nil, markerURL: markerURL)
            try materializer.writeMarker(marker, at: markerURL)

            // ── Step 4: materialize (no scope arg → cwd resolution) ────────────────
            var matCmd = try MaterializeCommand.parse([
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
            ])
            try matCmd._run(cwd: projectDir)

            let envPath = projectDir.appendingPathComponent(".env")
            let envContent = try String(contentsOf: envPath, encoding: .utf8)
            #expect(envContent.contains("API_KEY=sk-live-abc"))

            // ── Step 5: hand-edit the .env ─────────────────────────────────────────
            let edited = envContent.replacingOccurrences(of: "API_KEY=sk-live-abc", with: "API_KEY=sk-live-xyz")
            try edited.write(to: envPath, atomically: true, encoding: .utf8)

            // ── Step 6: update (no scope arg → cwd resolution) ────────────────────
            var updateCmd = try UpdateCommand.parse([
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
            ])
            try updateCmd._run(cwd: projectDir)

            // ── Step 7: get — assert new value in vault ────────────────────────────
            var getCmd2 = try GetCommand.parse([
                "--vault", vaultURL.path,
                "--age-key", keyURL.path,
                scopeID, "API_KEY",
            ])
            let updatedValue = try getCmd2.fetchValue()
            #expect(updatedValue == "sk-live-xyz")

            // ── Step 8: clean --yes ────────────────────────────────────────────────
            var cleanCmd = try CleanCommand.parse([
                "--vault", vaultURL.path,
                "--yes",
            ])
            try cleanCmd._run(cwd: projectDir)

            // Single owned key → file becomes empty → deleted.
            #expect(!FileManager.default.fileExists(atPath: envPath.path))
        }
    }
}
