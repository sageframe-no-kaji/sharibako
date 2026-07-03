import Foundation
import Testing

@testable import SharibakoCLI
@testable import SharibakoCore

// MARK: - Helpers

/// Creates an ephemeral project directory with the given `.env` content,
/// calls `body`, then removes the directory.
private func withProjectDir(
    env: String,
    _ body: (URL) throws -> Void
) throws {
    let projectDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("init-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: projectDir) }
    if !env.isEmpty {
        try env.write(
            to: projectDir.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )
    }
    try body(projectDir)
}

/// Builds a scripted `InitCommand` already set up with `--vault` and `--age-key`.
private func makeInitCommand(vaultURL: URL, keyURL: URL, extraArgs: [String] = []) throws -> InitCommand {
    let args = ["--vault", vaultURL.path, "--age-key", keyURL.path] + extraArgs
    return try InitCommand.parse(args)
}

// MARK: - InitCommandTests

@Suite("InitCommand")
struct InitCommandTests {
    // MARK: - Fresh init, mixed decisions

    /// Full five-decision walk: importAsLocal, linkToShared, moveToShared, leaveAlone, skip.
    @Test("fresh init: all five decision types write correct vault artefacts")
    func freshInitMixedDecisions() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            // Pre-seed a shared entry so linkToShared can resolve it.
            let coreForSeed = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
            try coreForSeed.addSharedEntry("existing-shared", value: "shared-value")

            let envContent = """
                OPENAI_API_KEY=sk-test
                EXISTING_SHARED=linked-value
                NEW_SHARED_KEY=promoted-value
                DEBUG=true
                TEMP_KEY=temp
                """

            try withProjectDir(env: envContent) { projectDir in
                let source = ScriptedIngestDecisionSource(decisions: [
                    "OPENAI_API_KEY": .importAsLocal(key: "OPENAI_API_KEY"),
                    "EXISTING_SHARED": .linkToShared(key: "EXISTING_SHARED", sharedID: "existing-shared"),
                    "NEW_SHARED_KEY": .moveToShared(key: "NEW_SHARED_KEY", newSharedID: "promoted"),
                    "DEBUG": .leaveAlone(key: "DEBUG"),
                    "TEMP_KEY": .skip(key: "TEMP_KEY"),
                ])
                // lineReader: scope-ID → "" (accept suggestion), scope-type → "" (default)
                var lineReaderQueue = ["", ""]
                let lineReader = { () -> String? in
                    lineReaderQueue.isEmpty ? nil : lineReaderQueue.removeFirst()
                }
                var cmd = try makeInitCommand(vaultURL: vaultURL, keyURL: keyURL)
                try cmd._run(cwd: projectDir, decisionSource: source, lineReader: lineReader)

                // Marker exists and binds a scope.
                let markerURL = projectDir.appendingPathComponent(".sharibako")
                #expect(FileManager.default.fileExists(atPath: markerURL.path))
                let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
                let materializer = Materializer(vaultCore: vault, vaultURL: vaultURL)
                let marker = try materializer.loadMarker(at: markerURL)

                // importAsLocal: OPENAI_API_KEY encrypted in scope
                #expect(try vault.getValue("OPENAI_API_KEY", inScope: marker.scope) == "sk-test")

                // linkToShared: EXISTING_SHARED has a .link file pointing at "existing-shared"
                let infos = try vault.inspect(marker.scope)
                let linkInfo = infos.first { $0.key == "EXISTING_SHARED" }
                if case .link(let sharedID) = linkInfo?.kind {
                    #expect(sharedID == "existing-shared")
                } else {
                    Issue.record("EXISTING_SHARED should be a .link, got \(String(describing: linkInfo))")
                }

                // moveToShared: "promoted" shared entry created and linked
                #expect(try vault.listShared().contains("promoted"))
                let movedInfo = infos.first { $0.key == "NEW_SHARED_KEY" }
                if case .link(let sharedID) = movedInfo?.kind {
                    #expect(sharedID == "promoted")
                } else {
                    Issue.record("NEW_SHARED_KEY should link to 'promoted', got \(String(describing: movedInfo))")
                }

                // leaveAlone / skip: nothing written for DEBUG or TEMP_KEY
                #expect(!infos.contains { $0.key == "DEBUG" })
                #expect(!infos.contains { $0.key == "TEMP_KEY" })

                // Source .env is byte-for-byte unchanged (Decision 4).
                let envPath = projectDir.appendingPathComponent(".env")
                let envOnDisk = try String(contentsOf: envPath, encoding: .utf8)
                #expect(envOnDisk == envContent)
            }
        }
    }

    // MARK: - Scope ID: default vs override

    @Test("scope ID: Enter accepts the suggested default")
    func scopeIDAcceptsDefault() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try withProjectDir(env: "API=value\n") { projectDir in
                let source = ScriptedIngestDecisionSource.allImportLocal()
                // Return "" for scope-ID (accept suggestion) and "" for scope-type (default).
                var lineReaderQueue = ["", ""]
                let lineReader = { () -> String? in
                    lineReaderQueue.isEmpty ? nil : lineReaderQueue.removeFirst()
                }
                var cmd = try makeInitCommand(vaultURL: vaultURL, keyURL: keyURL)
                try cmd._run(cwd: projectDir, decisionSource: source, lineReader: lineReader)

                // Marker exists; scope ID is derived from the directory name.
                let markerURL = projectDir.appendingPathComponent(".sharibako")
                let vault = try VaultCore(vaultURL: vaultURL)
                let materializer = Materializer(vaultCore: vault, vaultURL: vaultURL)
                let marker = try materializer.loadMarker(at: markerURL)
                #expect(!marker.scope.isEmpty)
                // Scope exists in vault.
                #expect(try vault.listScopes().map(\.identity).contains(marker.scope))
            }
        }
    }

    @Test("scope ID: typed value overrides the suggestion")
    func scopeIDOverride() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try withProjectDir(env: "API=value\n") { projectDir in
                let source = ScriptedIngestDecisionSource.allImportLocal()
                // Return "my-custom-scope" for ID, "" for type.
                var lineReaderQueue = ["my-custom-scope", ""]
                let lineReader = { () -> String? in
                    lineReaderQueue.isEmpty ? nil : lineReaderQueue.removeFirst()
                }
                var cmd = try makeInitCommand(vaultURL: vaultURL, keyURL: keyURL)
                try cmd._run(cwd: projectDir, decisionSource: source, lineReader: lineReader)

                let markerURL = projectDir.appendingPathComponent(".sharibako")
                let vault = try VaultCore(vaultURL: vaultURL)
                let materializer = Materializer(vaultCore: vault, vaultURL: vaultURL)
                let marker = try materializer.loadMarker(at: markerURL)
                #expect(marker.scope == "my-custom-scope")
            }
        }
    }

    @Test("scope ID collision: warns and reuses existing scope idempotently on confirmation")
    func scopeIDCollisionConfirmed() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            // Pre-seed scope "existing-scope" in the vault.
            try CLITestSupport.writeScope("existing-scope", in: vaultURL)

            try withProjectDir(env: "API=value\n") { projectDir in
                let source = ScriptedIngestDecisionSource.allImportLocal()
                // ID → "existing-scope", collision confirmation → "y", type → "".
                var lineReaderQueue = ["existing-scope", "y", ""]
                let lineReader = { () -> String? in
                    lineReaderQueue.isEmpty ? nil : lineReaderQueue.removeFirst()
                }
                var cmd = try makeInitCommand(vaultURL: vaultURL, keyURL: keyURL)
                try cmd._run(cwd: projectDir, decisionSource: source, lineReader: lineReader)

                let markerURL = projectDir.appendingPathComponent(".sharibako")
                let vault = try VaultCore(vaultURL: vaultURL)
                let materializer = Materializer(vaultCore: vault, vaultURL: vaultURL)
                let marker = try materializer.loadMarker(at: markerURL)
                // Scope reused idempotently.
                #expect(marker.scope == "existing-scope")
                // Original scope type preserved (pre-seeded as projectDev by writeScope).
                let scopeMeta = try vault.getScope("existing-scope")
                #expect(scopeMeta.type == .projectDev)
            }
        }
    }

    // MARK: - First-run offer

    @Test("--no-generate throws when no age key file is present")
    func noGenerateThrowsWhenKeyMissing() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            let nonExistentKey = FileManager.default.temporaryDirectory
                .appendingPathComponent("sharibako-no-such-key-\(UUID().uuidString).age")
            // Do NOT create the file.

            try withProjectDir(env: "API=value\n") { projectDir in
                let cmd = try InitCommand.parse([
                    "--vault", vaultURL.path,
                    "--age-key", nonExistentKey.path,
                    "--no-generate",
                ])
                #expect(throws: CLIError.ageKeyFileNotFound(path: nonExistentKey)) {
                    try cmd._run(cwd: projectDir)
                }
            }
        }
    }

    // MARK: - Re-init reconcile (Decision 7)

    @Test("re-init: only new keys are presented to the decision source; existing keys untouched")
    func reInitReconcile() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try withProjectDir(env: "KEY_A=val-a\n") { projectDir in
                // --- First init: import KEY_A ---
                let firstSource = ScriptedIngestDecisionSource(
                    decisions: ["KEY_A": .importAsLocal(key: "KEY_A")]
                )
                var firstReader = ["", ""]
                var firstCmd = try makeInitCommand(vaultURL: vaultURL, keyURL: keyURL)
                try firstCmd._run(
                    cwd: projectDir,
                    decisionSource: firstSource
                ) { firstReader.isEmpty ? nil : firstReader.removeFirst() }

                // Add KEY_B to .env.
                let newEnv = "KEY_A=val-a\nKEY_B=val-b\n"
                try newEnv.write(
                    to: projectDir.appendingPathComponent(".env"),
                    atomically: true,
                    encoding: .utf8
                )

                // --- Re-init: only KEY_B should be presented ---
                // Use a source that skips unknown keys; KEY_A must NOT re-appear.
                let reInitSource = ScriptedIngestDecisionSource(
                    decisions: ["KEY_B": .importAsLocal(key: "KEY_B")]
                ) { key in .skip(key: key) }
                // Re-init does not prompt scope ID.
                var reInitCmd = try makeInitCommand(vaultURL: vaultURL, keyURL: keyURL)
                try reInitCmd._run(cwd: projectDir, decisionSource: reInitSource) { nil }

                let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
                let markerURL = projectDir.appendingPathComponent(".sharibako")
                let materializer = Materializer(vaultCore: vault, vaultURL: vaultURL)
                let marker = try materializer.loadMarker(at: markerURL)

                // KEY_A still present with original value.
                #expect(try vault.getValue("KEY_A", inScope: marker.scope) == "val-a")
                // KEY_B now imported.
                #expect(try vault.getValue("KEY_B", inScope: marker.scope) == "val-b")
            }
        }
    }

    @Test("re-init: directory is not silently rebound to a different scope")
    func reInitDoesNotRebind() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try withProjectDir(env: "K=v\n") { projectDir in
                // First init.
                let firstSource = ScriptedIngestDecisionSource.allImportLocal()
                var firstQueue = ["original-scope", ""]
                var firstCmd = try makeInitCommand(vaultURL: vaultURL, keyURL: keyURL)
                try firstCmd._run(
                    cwd: projectDir,
                    decisionSource: firstSource
                ) { firstQueue.isEmpty ? nil : firstQueue.removeFirst() }

                // Re-init (no new keys in .env, so nothing to present — but marker is preserved).
                let reInitSource = ScriptedIngestDecisionSource.allSkip()
                var reInitCmd = try makeInitCommand(vaultURL: vaultURL, keyURL: keyURL)
                try reInitCmd._run(cwd: projectDir, decisionSource: reInitSource) { nil }

                let vault = try VaultCore(vaultURL: vaultURL)
                let materializer = Materializer(vaultCore: vault, vaultURL: vaultURL)
                let marker = try materializer.loadMarker(at: projectDir.appendingPathComponent(".sharibako"))
                // Scope ID unchanged.
                #expect(marker.scope == "original-scope")
            }
        }
    }

    // MARK: - Empty .env

    @Test("empty .env: refuses, writes nothing — no empty scope or marker as chaff")
    func emptyEnvRefuses() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            // Directory with no .env file at all (ingest returns empty detectedKeys).
            let projectDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("init-empty-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: projectDir) }

            var cmd = try makeInitCommand(vaultURL: vaultURL, keyURL: keyURL)
            // allSkip is a safeguard — the decision source must not be reached for an empty proposal.
            #expect(throws: CLIError.nothingToInitialize(directory: projectDir)) {
                try cmd._run(
                    cwd: projectDir,
                    decisionSource: ScriptedIngestDecisionSource.allSkip()
                ) { nil }
            }

            // Nothing written: no marker, no scope in the vault.
            let markerURL = projectDir.appendingPathComponent(".sharibako")
            #expect(!FileManager.default.fileExists(atPath: markerURL.path))
            let vault = try VaultCore(vaultURL: vaultURL)
            #expect(try vault.listScopes().isEmpty)
        }
    }

    // MARK: - Non-TTY refusal

    @Test("non-TTY: notInteractiveTerminal surfaces when dashboard refuses")
    func nonTTYRefusal() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, keyURL in
            try withProjectDir(env: "SECRET=value\n") { projectDir in
                // Inject a prompt that immediately throws notInteractiveTerminal.
                var nonTTYPrompt = DashboardIngestPrompt()
                nonTTYPrompt.dashboardRunner = { _, _, _ in throw CLIError.notInteractiveTerminal }
                // Provide "" responses for scope-ID and scope-type prompts.
                var lineReaderQueue = ["", ""]
                let lineReader = { () -> String? in
                    lineReaderQueue.isEmpty ? nil : lineReaderQueue.removeFirst()
                }
                var cmd = try makeInitCommand(vaultURL: vaultURL, keyURL: keyURL)
                #expect(throws: CLIError.notInteractiveTerminal) {
                    try cmd._run(cwd: projectDir, decisionSource: nonTTYPrompt, lineReader: lineReader)
                }
            }
        }
    }
}
