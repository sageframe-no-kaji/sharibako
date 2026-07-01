import Foundation

@testable import SharibakoCore

/// Ephemeral age key pair generated for the duration of one encryption test.
///
/// The private key file lives in a fresh temp directory and is removed by
/// `cleanup()`. The public key is extracted at generation time so tests can
/// pass it straight to `age --recipient` without re-parsing the header.
struct AgeKeyFixture {
    /// URL of the freshly generated age private-key file.
    let privateKeyURL: URL

    /// The recipient public key parsed out of the private-key file header.
    let publicKey: String

    /// Shells out to `age-keygen -o <tempDir>/age-key.txt` and parses the result.
    ///
    /// - Throws: `VaultError.shellNotFound(name:)` if `age-keygen` is not on PATH;
    ///   `VaultError.ageInvocationFailed` if key generation fails or the output
    ///   file has no `# public key:` header line.
    static func generate() throws -> Self {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharibako-agekey-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let keyURL = tempDir.appendingPathComponent("age-key.txt")
        let ageKeygen = try Shell.findExecutable("age-keygen")
        let result = try Shell.run(ageKeygen, ["-o", keyURL.path])
        guard result.exitCode == 0 else {
            throw VaultError.ageInvocationFailed(exitCode: result.exitCode, stderr: result.stderr)
        }

        let contents = try String(contentsOf: keyURL, encoding: .utf8)
        let prefix = "# public key: "
        var publicKey: String?
        for line in contents.split(whereSeparator: \.isNewline) where line.hasPrefix(prefix) {
            publicKey = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        guard let publicKey else {
            throw VaultError.ageInvocationFailed(
                exitCode: -1,
                stderr: "no '# public key:' header in generated file"
            )
        }

        return Self(privateKeyURL: keyURL, publicKey: publicKey)
    }

    /// Deletes the private-key file and its containing temp directory.
    func cleanup() throws {
        try FileManager.default.removeItem(at: privateKeyURL.deletingLastPathComponent())
    }
}
