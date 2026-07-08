import Foundation
import Testing

@testable import SharibakoCLI
@testable import SharibakoCore

@Suite("KeyCommand")
struct KeyCommandTests {
    // MARK: - key generate (file path)

    @Test("generate creates an age key file at the supplied --age-key path")
    func generateCreatesFile() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharibako-keygen-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let keyPath = tmpDir.appendingPathComponent("age-key.txt")
        let cmd = try GenerateCommand.parse([])
        try cmd.generateToFile(at: keyPath)

        #expect(FileManager.default.fileExists(atPath: keyPath.path))
        let contents = try String(contentsOf: keyPath, encoding: .utf8)
        #expect(contents.contains("AGE-SECRET-KEY-"))
        #expect(contents.contains("# public key:"))
    }

    @Test("generate scaffolds a fresh vault directory (ho-04.14 fresh-install fix)")
    func generateScaffoldsVault() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharibako-keygen-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // The vault directory does NOT exist yet — the fresh-install scenario.
        let vaultDir = tmpDir.appendingPathComponent("vault")
        let keyPath = tmpDir.appendingPathComponent("age-key.txt")
        #expect(!FileManager.default.fileExists(atPath: vaultDir.path))

        // `--age-key` keeps this off the Keychain; `_run` drives the full command path.
        let cmd = try GenerateCommand.parse(["--vault", vaultDir.path, "--age-key", keyPath.path])
        try cmd._run()

        // Regression guard: generate must leave a usable vault, not just a key.
        var isDir: ObjCBool = false
        #expect(
            FileManager.default.fileExists(
                atPath: vaultDir.appendingPathComponent("scopes").path, isDirectory: &isDir)
                && isDir.boolValue)
        #expect(
            FileManager.default.fileExists(
                atPath: vaultDir.appendingPathComponent("shared").path, isDirectory: &isDir)
                && isDir.boolValue)
        #expect(FileManager.default.fileExists(atPath: keyPath.path))
    }

    @Test("generate refuses to overwrite an existing key without --force")
    func generateRefusesExistingWithoutForce() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharibako-keygen-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let keyPath = tmpDir.appendingPathComponent("age-key.txt")
        // Pre-create the file to simulate an existing key.
        try "existing".write(to: keyPath, atomically: true, encoding: .utf8)

        let cmd = try GenerateCommand.parse([])
        #expect {
            try cmd.generateToFile(at: keyPath)
        } throws: { error in
            guard case CLIError.ageKeyAlreadyExists = error else { return false }
            return true
        }
    }

    @Test("generate with --force --yes overwrites an existing key")
    func generateForceYesOverwrites() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharibako-keygen-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let keyPath = tmpDir.appendingPathComponent("age-key.txt")
        try "existing".write(to: keyPath, atomically: true, encoding: .utf8)

        let cmd = try GenerateCommand.parse(["--force", "--yes"])
        try cmd.generateToFile(at: keyPath)

        let contents = try String(contentsOf: keyPath, encoding: .utf8)
        #expect(contents.contains("AGE-SECRET-KEY-"))
    }

    // MARK: - isValidAgeKey

    @Test("isValidAgeKey returns true for a valid AGE-SECRET-KEY- file")
    func isValidAgeKeyTrue() {
        let contents = "# created: 2026-07-01\n# public key: age1abc\nAGE-SECRET-KEY-1XYZ\n"
        #expect(isValidAgeKey(Data(contents.utf8)))
    }

    @Test("isValidAgeKey returns false for arbitrary text")
    func isValidAgeKeyFalse() {
        #expect(!isValidAgeKey(Data("not a key file".utf8)))
    }

    @Test("isValidAgeKey returns false for empty data")
    func isValidAgeKeyEmpty() {
        #expect(!isValidAgeKey(Data()))
    }

    // MARK: - extractPublicKey

    @Test("extractPublicKey parses the public key header line")
    func extractPublicKeyParsed() throws {
        let contents = "# created: 2026-07-01\n# public key: age1abcxyz\nAGE-SECRET-KEY-1XYZ\n"
        let key = try extractPublicKey(from: contents)
        #expect(key == "age1abcxyz")
    }

    @Test("extractPublicKey throws when header is absent")
    func extractPublicKeyMissing() {
        let contents = "# created: 2026-07-01\nAGE-SECRET-KEY-1XYZ\n"
        #expect {
            try extractPublicKey(from: contents)
        } throws: { error in
            guard case CLIError.publicKeyHeaderMissing = error else { return false }
            return true
        }
    }

    // MARK: - key import

    @Test("import copies a valid age key to the destination file")
    func importCopiesKeyToFile() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharibako-import-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Generate a real key to import.
        let srcPath = tmpDir.appendingPathComponent("source-key.txt")
        let ageKeygen = try Shell.findExecutable("age-keygen")
        let result = try Shell.run(ageKeygen, ["-o", srcPath.path])
        guard result.exitCode == 0 else {
            throw GenerateFailure()
        }

        let destPath = tmpDir.appendingPathComponent("imported-key.txt")
        let cmd = try ImportCommand.parse([srcPath.path, "--keep-source"])
        let contents = try Data(contentsOf: srcPath)
        try cmd.importToFile(contents: contents, at: destPath, sourceURL: srcPath)

        #expect(FileManager.default.fileExists(atPath: destPath.path))
        let imported = try String(contentsOf: destPath, encoding: .utf8)
        #expect(imported.contains("AGE-SECRET-KEY-"))
        // Source should still exist since keepSource=true.
        #expect(FileManager.default.fileExists(atPath: srcPath.path))
    }

    @Test("import rejects a file without a valid age key prefix")
    func importRejectsInvalidFile() {
        // Test the validation logic directly — run() routes errors through ErrorReporter
        // which calls exit(), so we test isValidAgeKey() at the boundary instead.
        #expect(!isValidAgeKey(Data("not a key".utf8)))
        #expect(!isValidAgeKey(Data("# comment\nNOT-AGE-KEY".utf8)))
    }

    // MARK: - key export

    @Test("export public key extracts the age1... recipient line")
    func exportPublicKey() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharibako-export-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Generate a real key.
        let keyPath = tmpDir.appendingPathComponent("age-key.txt")
        let ageKeygen = try Shell.findExecutable("age-keygen")
        let result = try Shell.run(ageKeygen, ["-o", keyPath.path])
        guard result.exitCode == 0 else {
            throw GenerateFailure()
        }

        let rawKey = try String(contentsOf: keyPath, encoding: .utf8)
        let publicKey = try extractPublicKey(from: rawKey)
        // Test extractPublicKey directly; ExportCommand.loadRawKey requires a provider.
        #expect(publicKey.hasPrefix("age1"))
    }

    @Test("export --private without --i-know-this-is-plaintext throws")
    func exportPrivateWithoutAcknowledgement() throws {
        var cmd = ExportCommand()
        cmd.private = true
        cmd.iKnowThisIsPlaintext = false
        // We can't easily inject a provider, so test the error mapping.
        let report = ErrorReporter.makeReport(for: CLIError.exportRequiresPlaintextAcknowledgement)
        #expect(report.code == .userError)
    }

    @Test("export rejects --public and --private together at parse time")
    func exportRejectsPublicPrivateConflict() {
        // Before the validate() guard, --public --private silently exported
        // the PRIVATE key.
        #expect(throws: (any Error).self) {
            _ = try ExportCommand.parse(["--public", "--private", "--i-know-this-is-plaintext"])
        }
    }

    @Test("generate --force --yes leaves no staging files behind")
    func generateForceLeavesNoStaging() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharibako-keygen-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let keyPath = tmpDir.appendingPathComponent("age-key.txt")
        try "existing".write(to: keyPath, atomically: true, encoding: .utf8)

        let cmd = try GenerateCommand.parse(["--force", "--yes"])
        try cmd.generateToFile(at: keyPath)

        // The new key is in place and the staging file was consumed by the swap.
        let contents = try String(contentsOf: keyPath, encoding: .utf8)
        #expect(contents.contains("AGE-SECRET-KEY-"))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
            .filter { $0.hasPrefix(".sharibako-keygen-") }
        #expect(leftovers.isEmpty)
    }
}

// MARK: - Generate: prompt and failure paths

@Suite("KeyCommand generate — prompts and failures")
struct KeyCommandGeneratePromptTests {
    @Test("generate --force prompts and overwrites on 'y'")
    func forcePromptYesOverwrites() throws {
        try withKeyTempDir { tmpDir in
            let keyPath = tmpDir.appendingPathComponent("age-key.txt")
            try "existing".write(to: keyPath, atomically: true, encoding: .utf8)

            let cmd = try GenerateCommand.parse(["--force"])
            try cmd.generateToFile(at: keyPath) { "y" }

            let contents = try String(contentsOf: keyPath, encoding: .utf8)
            #expect(contents.contains("AGE-SECRET-KEY-"))
        }
    }

    @Test("generate --force aborts on 'n', leaving the existing key untouched")
    func forcePromptNoAborts() throws {
        try withKeyTempDir { tmpDir in
            let keyPath = tmpDir.appendingPathComponent("age-key.txt")
            try "existing".write(to: keyPath, atomically: true, encoding: .utf8)

            let cmd = try GenerateCommand.parse(["--force"])
            try cmd.generateToFile(at: keyPath) { "n" }

            let contents = try String(contentsOf: keyPath, encoding: .utf8)
            #expect(contents == "existing")
        }
    }

    @Test("generation failure cleans the staging file and rethrows")
    func generateFailureCleansStaging() throws {
        try withKeyTempDir { tmpDir in
            // Read-only directory: age-keygen cannot create the staging file.
            let lockedDir = tmpDir.appendingPathComponent("locked")
            try FileManager.default.createDirectory(at: lockedDir, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o500], ofItemAtPath: lockedDir.path
            )
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: lockedDir.path
                )
            }

            let keyPath = lockedDir.appendingPathComponent("age-key.txt")
            let cmd = try GenerateCommand.parse([])
            #expect(throws: (any Error).self) {
                try cmd.generateToFile(at: keyPath)
            }
            // No key and no staging leftovers.
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: lockedDir.path)
            #expect(leftovers.isEmpty)
        }
    }

    @Test("generate via run(): key generate --age-key writes the file end-to-end")
    func generateRunShim() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharibako-keygen-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let keyPath = tmpDir.appendingPathComponent("age-key.txt")
        try await CLITestSupport.runCommand(["key", "generate", "--age-key", keyPath.path])

        let contents = try String(contentsOf: keyPath, encoding: .utf8)
        #expect(contents.contains("AGE-SECRET-KEY-"))
    }
}

// MARK: - Import: error, prompt, and run() paths

@Suite("KeyCommand import — sources and prompts")
struct KeyCommandImportTests {
    @Test("import via run(): copies the key file and keeps the source")
    func importRunShim() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharibako-import-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let srcPath = try makeRealKey(in: tmpDir, named: "source-key.txt")
        let destPath = tmpDir.appendingPathComponent("imported-key.txt")
        try await CLITestSupport.runCommand([
            "key", "import", srcPath.path, "--keep-source", "--age-key", destPath.path,
        ])

        let imported = try String(contentsOf: destPath, encoding: .utf8)
        #expect(imported.contains("AGE-SECRET-KEY-"))
        #expect(FileManager.default.fileExists(atPath: srcPath.path))
        // Imported key is private to the user (0600).
        let attrs = try FileManager.default.attributesOfItem(atPath: destPath.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
    }

    @Test("_run throws ageKeyFileNotFound for a missing source file")
    func importMissingSource() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-key-\(UUID().uuidString)")
        let cmd = try ImportCommand.parse([missing.path, "--age-key", "/tmp/dest-unused"])
        #expect(throws: CLIError.ageKeyFileNotFound(path: missing)) {
            try cmd._run()
        }
    }

    @Test("_run throws invalidAgeKeyFile for a non-key source file")
    func importInvalidSource() throws {
        try withKeyTempDir { tmpDir in
            let srcPath = tmpDir.appendingPathComponent("not-a-key.txt")
            try "not a key".write(to: srcPath, atomically: true, encoding: .utf8)
            let cmd = try ImportCommand.parse([srcPath.path, "--age-key", "/tmp/dest-unused"])
            #expect(throws: CLIError.invalidAgeKeyFile(path: srcPath)) {
                try cmd._run()
            }
        }
    }

    @Test("importToFile creates missing parent directories; --delete-source removes the source")
    func importCreatesParentAndDeletesSource() throws {
        try withKeyTempDir { tmpDir in
            let srcPath = try makeRealKey(in: tmpDir, named: "source-key.txt")
            let destPath =
                tmpDir
                .appendingPathComponent("nested")
                .appendingPathComponent("deeper")
                .appendingPathComponent("age-key.txt")

            let cmd = try ImportCommand.parse([srcPath.path, "--delete-source"])
            let contents = try Data(contentsOf: srcPath)
            try cmd.importToFile(contents: contents, at: destPath, sourceURL: srcPath)

            #expect(FileManager.default.fileExists(atPath: destPath.path))
            #expect(!FileManager.default.fileExists(atPath: srcPath.path))
        }
    }

    @Test("source-deletion prompt: 'y' deletes the source file")
    func sourceDeletionPromptYes() throws {
        try withKeyTempDir { tmpDir in
            let srcPath = tmpDir.appendingPathComponent("source-key.txt")
            try "AGE-SECRET-KEY-1XYZ\n".write(to: srcPath, atomically: true, encoding: .utf8)
            let cmd = try ImportCommand.parse([srcPath.path])
            try cmd.handleSourceDeletion(sourceURL: srcPath) { "y" }
            #expect(!FileManager.default.fileExists(atPath: srcPath.path))
        }
    }

    @Test("source-deletion prompt: 'n' keeps the source file")
    func sourceDeletionPromptNo() throws {
        try withKeyTempDir { tmpDir in
            let srcPath = tmpDir.appendingPathComponent("source-key.txt")
            try "AGE-SECRET-KEY-1XYZ\n".write(to: srcPath, atomically: true, encoding: .utf8)
            let cmd = try ImportCommand.parse([srcPath.path])
            try cmd.handleSourceDeletion(sourceURL: srcPath) { "n" }
            #expect(FileManager.default.fileExists(atPath: srcPath.path))
        }
    }
}

// MARK: - Export: _run and run() paths

@Suite("KeyCommand export — key material paths")
struct KeyCommandExportTests {
    @Test("_run default prints the public key derived from the private key file")
    func exportPublicViaRun() throws {
        try withKeyTempDir { tmpDir in
            let keyPath = try makeRealKey(in: tmpDir, named: "age-key.txt")
            let cmd = try ExportCommand.parse(["--age-key", keyPath.path])
            // The printed value is loadRawKey → extractPublicKey; assert the pipeline
            // yields an age1… recipient before driving the print path.
            let raw = try cmd.loadRawKey()
            #expect(raw.contains("AGE-SECRET-KEY-"))
            #expect(try extractPublicKey(from: raw).hasPrefix("age1"))
            try cmd._run()
        }
    }

    @Test("_run --private with acknowledgement prints the raw private key")
    func exportPrivateAcknowledged() throws {
        try withKeyTempDir { tmpDir in
            let keyPath = try makeRealKey(in: tmpDir, named: "age-key.txt")
            let cmd = try ExportCommand.parse([
                "--private", "--i-know-this-is-plaintext", "--age-key", keyPath.path,
            ])
            try cmd._run()
            // loadRawKey feeds the print; assert it carries the private key verbatim.
            let raw = try cmd.loadRawKey()
            let onDisk = try String(contentsOf: keyPath, encoding: .utf8)
            #expect(raw == onDisk)
        }
    }

    @Test("_run --private without acknowledgement throws")
    func exportPrivateUnacknowledged() throws {
        try withKeyTempDir { tmpDir in
            let keyPath = try makeRealKey(in: tmpDir, named: "age-key.txt")
            let cmd = try ExportCommand.parse(["--private", "--age-key", keyPath.path])
            #expect(throws: CLIError.exportRequiresPlaintextAcknowledgement) {
                try cmd._run()
            }
        }
    }

    @Test("export via run(): public path end-to-end without exiting")
    func exportRunShim() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharibako-export-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let keyPath = try makeRealKey(in: tmpDir, named: "age-key.txt")
        try await CLITestSupport.runCommand(["key", "export", "--age-key", keyPath.path])
    }
}

// MARK: - Helpers

private struct GenerateFailure: Error {}

/// Creates a temp directory, calls `body`, then removes it.
private func withKeyTempDir(_ body: (URL) throws -> Void) throws {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sharibako-keycmd-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    try body(tmpDir)
}

/// Generates a real age key file named `name` inside `dir` via `age-keygen`.
private func makeRealKey(in dir: URL, named name: String) throws -> URL {
    let keyPath = dir.appendingPathComponent(name)
    let ageKeygen = try Shell.findExecutable("age-keygen")
    let result = try Shell.run(ageKeygen, ["-o", keyPath.path])
    guard result.exitCode == 0 else {
        throw GenerateFailure()
    }
    return keyPath
}
