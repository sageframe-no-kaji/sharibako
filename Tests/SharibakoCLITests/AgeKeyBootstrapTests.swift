import Foundation
import Testing

@testable import SharibakoCLI
@testable import SharibakoCore

@Suite("AgeKeyBootstrap")
struct AgeKeyBootstrapTests {
    @Test("generateToFile creates missing parent directories, sets 0600, and returns the recipient")
    func generateToFileFreshKey() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharibako-bootstrap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let keyURL =
            root
            .appendingPathComponent("nested")
            .appendingPathComponent("age-key.txt")

        let publicKey = try AgeKeyBootstrap.generateToFile(at: keyURL)

        #expect(publicKey.hasPrefix("age1"))
        let contents = try String(contentsOf: keyURL, encoding: .utf8)
        #expect(contents.contains("AGE-SECRET-KEY-"))
        let attrs = try FileManager.default.attributesOfItem(atPath: keyURL.path)
        let permissions = attrs[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test("generateToFile throws ageInvocationFailed when the destination cannot be written")
    func generateToFileUnwritableDestination() throws {
        // A directory at the destination path makes `age-keygen -o` exit non-zero.
        let dirAsDestination = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharibako-bootstrap-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dirAsDestination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dirAsDestination) }

        let error = #expect(throws: VaultError.self) {
            _ = try AgeKeyBootstrap.generateToFile(at: dirAsDestination)
        }
        guard case .ageInvocationFailed(let exitCode, _) = error else {
            Issue.record("expected ageInvocationFailed, got \(String(describing: error))")
            return
        }
        #expect(exitCode != 0)
    }
}
