import Foundation
import SharibakoCore

/// Shared age key generation logic for `GenerateCommand` and `InitCommand`.
///
/// Both commands need to shell out to `age-keygen`, fix permissions, and
/// extract the recipient public key. Factoring the core here keeps the two
/// callers in sync without duplicating the `age-keygen` shell-out.
///
/// Neither method checks whether a key already exists — callers are
/// responsible for any overwrite guard before calling these functions.
enum AgeKeyBootstrap {
    /// Generates a fresh age key at `path`, sets permissions to 0600, and returns
    /// the `age1…` recipient public key extracted from the file's header.
    ///
    /// - Parameter path: Destination file for the age private key. Parent
    ///   directories are created when absent.
    /// - Returns: The `age1…` recipient string from the `# public key:` header.
    /// - Throws: `VaultError.shellNotFound` if `age-keygen` is not on PATH;
    ///   `VaultError.ageInvocationFailed` if `age-keygen` exits non-zero;
    ///   `CLIError.publicKeyHeaderMissing` if the file has no public-key header.
    static func generateToFile(at path: URL) throws -> String {
        let fileManager = FileManager.default
        let parent = path.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        let ageKeygen = try CLIShell.findExecutable("age-keygen")
        let result = try CLIShell.run(ageKeygen, ["-o", path.path])
        guard result.exitCode == 0 else {
            throw VaultError.ageInvocationFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        return try extractPublicKey(from: path)
    }

    #if os(macOS)
        /// Generates a fresh age key, stores it in the macOS Keychain under `.userPresence`,
        /// and returns the `age1…` recipient public key.
        ///
        /// Writes the key to a temporary file, calls `KeychainAgeKeyProvider.storeIdentity`,
        /// then deletes the temp file. The Keychain item is configured to require Touch ID
        /// (or password) on subsequent retrievals.
        ///
        /// - Returns: The `age1…` recipient string from the `# public key:` header.
        /// - Throws: `VaultError.shellNotFound` if `age-keygen` is not on PATH;
        ///   `VaultError.ageInvocationFailed` if `age-keygen` exits non-zero;
        ///   `CLIError.keychainStoreFailed` if the Keychain store fails;
        ///   `CLIError.publicKeyHeaderMissing` if the file has no public-key header.
        static func generateToKeychain() throws -> String {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("sharibako-keygen-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tempURL) }
            let ageKeygen = try CLIShell.findExecutable("age-keygen")
            let result = try CLIShell.run(ageKeygen, ["-o", tempURL.path])
            guard result.exitCode == 0 else {
                throw VaultError.ageInvocationFailed(exitCode: result.exitCode, stderr: result.stderr)
            }
            let data = try Data(contentsOf: tempURL)
            try KeychainAgeKeyProvider().storeIdentity(data)
            return try extractPublicKey(from: tempURL)
        }
    #endif
}
