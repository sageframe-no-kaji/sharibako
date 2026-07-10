import Foundation
import Yams

/// Resolves the Workshop's vault path, dev age-key path, and scan roots.
///
/// The GUI has no command-line flags (and no first-run wizard until ho-06), so
/// resolution mirrors the CLI's `VaultLocator` precedence minus the flag:
/// `SHARIBAKO_VAULT` environment variable, else `~/.sharibako/vault/`. Scan
/// roots come from the GUI's own config file at
/// `~/Library/Application Support/Sharibako/config.yaml`.
///
/// Every function takes its environment and home directory as parameters
/// (defaulting to live process values) so tests exercise every branch without
/// mutating process state.
enum WorkshopConfig {
    /// Determines the vault directory the Workshop should open, without
    /// checking that it exists.
    ///
    /// Priority: `SHARIBAKO_VAULT` env → `~/.sharibako/vault/`. Mirrors the
    /// CLI's `VaultLocator.intendedVaultURL` minus the `--vault` flag. Does
    /// not create anything; the caller decides what a missing vault means
    /// (the "no vault" empty state — never silent creation).
    static func resolveVaultURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let env = environment["SHARIBAKO_VAULT"] {
            return URL(fileURLWithPath: env)
        }
        return
            home
            .appendingPathComponent(".sharibako")
            .appendingPathComponent("vault")
    }

    /// Determines the file-based age key to use instead of the Keychain, or
    /// `nil` when the Keychain path applies.
    ///
    /// Priority: `SHARIBAKO_AGE_KEY` env → `nil`. Mirrors the CLI's
    /// `VaultLocator.resolveAgeKey` minus the `--age-key` flag. This is the
    /// dev/test bypass (ho-05 Decision 7): an unsigned debug build cannot
    /// reach the Keychain entitlement, so iteration runs against a file key.
    static func resolveDevAgeKeyURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard let env = environment["SHARIBAKO_AGE_KEY"] else {
            return nil
        }
        return URL(fileURLWithPath: env)
    }

    /// Returns `true` when `url` is an existing directory that looks like a
    /// vault (it contains a `scopes/` or `shared/` subdirectory).
    ///
    /// The subdirectory check distinguishes a real vault from an arbitrary
    /// empty directory so the Workshop shows the "no vault" state instead of
    /// an empty-but-open window. Either subdirectory counts because git drops
    /// empty directories on clone (ho-04.12 D8) — a cloned vault may carry
    /// only one of the two.
    static func isVaultDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return false
        }
        for marker in ["scopes", "shared"] {
            let sub = url.appendingPathComponent(marker)
            let exists = fileManager.fileExists(atPath: sub.path, isDirectory: &isDirectory)
            if exists && isDirectory.boolValue {
                return true
            }
        }
        return false
    }

    /// The Workshop's config file location: `~/Library/Application Support/Sharibako/config.yaml`.
    static func defaultConfigURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Sharibako")
            .appendingPathComponent("config.yaml")
    }

    /// Reads `scan_roots` from the config file, returning `[]` when the file
    /// is absent, unreadable, or has no `scan_roots` key.
    ///
    /// Degrading to `[]` (rather than throwing) is deliberate for v1: a
    /// missing or malformed config means "no roots configured yet", and the
    /// Rescan action (AT-03) responds by asking for a directory. ho-06's
    /// first-run flow owns config repair.
    static func loadScanRoots(configURL: URL) -> [URL] {
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8),
            let config = try? YAMLDecoder().decode(ConfigFile.self, from: contents),
            let roots = config.scanRoots
        else {
            return []
        }
        return roots.map { URL(fileURLWithPath: $0) }
    }

    /// Appends `root` to the config file's `scan_roots`, creating the file when absent.
    ///
    /// The parent directory is created too. Already-present roots are not
    /// duplicated.
    ///
    /// v1 note: the config file carries only `scan_roots`; this rewrite drops
    /// no other keys because none exist yet. Revisit when ho-06's first-run
    /// flow adds fields.
    static func persistScanRoot(_ root: URL, configURL: URL) throws {
        var paths = loadScanRoots(configURL: configURL).map(\.path)
        if !paths.contains(root.path) {
            paths.append(root.path)
        }
        let encoded = try YAMLEncoder().encode(ConfigFile(scanRoots: paths))
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoded.write(to: configURL, atomically: true, encoding: .utf8)
    }
}

/// Codable shape of `config.yaml`.
///
/// Snake-case keys per vault-wide convention.
private struct ConfigFile: Codable {
    /// Absolute directory paths the Materializer scans for `.sharibako` markers.
    let scanRoots: [String]?

    /// Maps the Swift property to the YAML `scan_roots` key.
    enum CodingKeys: String, CodingKey {
        case scanRoots = "scan_roots"
    }
}
