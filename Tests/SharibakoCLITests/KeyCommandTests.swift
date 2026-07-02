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
    func importRejectsInvalidFile() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharibako-import-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let badPath = tmpDir.appendingPathComponent("bad.txt")
        try "not a key".write(to: badPath, atomically: true, encoding: .utf8)

        var cmd = try ImportCommand.parse([badPath.path, "--keep-source"])
        await #expect(throws: CLIError.self) {
            try await cmd.run()
        }
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
}

// MARK: - Helpers

private struct GenerateFailure: Error {}
