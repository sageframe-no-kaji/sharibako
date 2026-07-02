import Foundation
import SharibakoCore

/// Resolves vault and age key paths from flags, environment variables, or defaults.
enum VaultLocator {
    /// Determines the vault directory to use for a command invocation.
    ///
    /// Priority: `--vault` flag → `SHARIBAKO_VAULT` env → `~/.sharibako/vault/`.
    /// Throws `VaultError.vaultNotFound(path:)` if the resolved path does not exist.
    static func resolve(globalFlag: URL?) throws -> URL {
        if let flag = globalFlag {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: flag.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                throw VaultError.vaultNotFound(path: flag)
            }
            return flag
        }
        if let env = ProcessInfo.processInfo.environment["SHARIBAKO_VAULT"] {
            let url = URL(fileURLWithPath: env)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                throw VaultError.vaultNotFound(path: url)
            }
            return url
        }
        let defaultURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".sharibako")
            .appendingPathComponent("vault")
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: defaultURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw VaultError.vaultNotFound(path: defaultURL)
        }
        return defaultURL
    }

    /// Determines the age key file to use, or `nil` when the Keychain should be used on macOS.
    ///
    /// Priority: `--age-key` flag → `SHARIBAKO_AGE_KEY` env → `nil`.
    /// A `nil` return means "use `KeychainAgeKeyProvider` on macOS."
    static func resolveAgeKey(globalFlag: URL?) -> URL? {
        if let flag = globalFlag {
            return flag
        }
        if let env = ProcessInfo.processInfo.environment["SHARIBAKO_AGE_KEY"] {
            return URL(fileURLWithPath: env)
        }
        return nil
    }

    /// Builds the appropriate `AgeKeyProvider` for the current platform and flags.
    ///
    /// Returns `FileAgeKeyProvider` when a path is resolved, or
    /// `KeychainAgeKeyProvider` on macOS when no path is configured.
    static func resolveProvider(globalFlag: URL?) -> any AgeKeyProvider {
        if let path = resolveAgeKey(globalFlag: globalFlag) {
            return FileAgeKeyProvider(path: path)
        }
        #if os(macOS)
            return KeychainAgeKeyProvider()
        #else
            // Linux without an explicit key path: caller should have supplied --age-key.
            // Return a FileAgeKeyProvider pointing at the default location; it will fail
            // with a clear error if the file doesn't exist.
            let defaultPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config")
                .appendingPathComponent("sharibako")
                .appendingPathComponent("age-key")
            return FileAgeKeyProvider(path: defaultPath)
        #endif
    }
}
