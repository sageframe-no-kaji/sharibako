import Foundation
import SharibakoCore

/// Resolves vault and age key paths from flags, environment variables, or defaults.
enum VaultLocator {
    /// Determines the vault directory a command *would* use, without checking that
    /// it exists.
    ///
    /// Priority: `--vault` flag → `SHARIBAKO_VAULT` env → `~/.sharibako/vault/`.
    /// Use this for vault CREATION (`key generate`), where the whole point is that
    /// the directory doesn't exist yet; use ``resolve(globalFlag:environment:home:)``
    /// for operations that require an existing vault.
    ///
    /// `environment` and `home` default to the live process values; tests inject
    /// both to exercise every branch without mutating process state.
    static func intendedVaultURL(
        globalFlag: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let flag = globalFlag {
            return flag
        }
        if let env = environment["SHARIBAKO_VAULT"] {
            return URL(fileURLWithPath: env)
        }
        return
            home
            .appendingPathComponent(".sharibako")
            .appendingPathComponent("vault")
    }

    /// Determines the vault directory to use for a command invocation, requiring it
    /// to exist.
    ///
    /// Same priority as ``intendedVaultURL(globalFlag:environment:home:)``, plus an
    /// existence check: throws `VaultError.vaultNotFound(path:)` if the resolved path
    /// is not an existing directory. The check is a safety net — a typo'd `--vault`
    /// must error rather than silently create a vault at the wrong place — so it stays
    /// on every read/write path.
    static func resolve(
        globalFlag: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> URL {
        let url = intendedVaultURL(globalFlag: globalFlag, environment: environment, home: home)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw VaultError.vaultNotFound(path: url)
        }
        return url
    }

    /// Determines the age key file to use, or `nil` when the Keychain should be used on macOS.
    ///
    /// Priority: `--age-key` flag → `SHARIBAKO_AGE_KEY` env → `nil`.
    /// A `nil` return means "use `KeychainAgeKeyProvider` on macOS."
    static func resolveAgeKey(
        globalFlag: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let flag = globalFlag {
            return flag
        }
        if let env = environment["SHARIBAKO_AGE_KEY"] {
            return URL(fileURLWithPath: env)
        }
        return nil
    }

    /// Builds the appropriate `AgeKeyProvider` for the current platform and flags.
    ///
    /// Returns `FileAgeKeyProvider` when a path is resolved, or
    /// `KeychainAgeKeyProvider` on macOS when no path is configured.
    static func resolveProvider(
        globalFlag: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> any AgeKeyProvider {
        if let path = resolveAgeKey(globalFlag: globalFlag, environment: environment) {
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
