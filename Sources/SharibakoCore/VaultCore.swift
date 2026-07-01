import Foundation
import Yams

/// Public entry point for reading and writing a Sharibako vault.
///
/// A `VaultCore` value binds to an on-disk vault directory. The AT-01 methods
/// cover the operations that don't require decryption; AT-02 extends the type
/// with age-driven read/write for `.age` files.
public struct VaultCore: Sendable {
    /// Absolute URL of the vault root (the directory containing `shared/` and `scopes/`).
    public let vaultURL: URL

    /// Binds to an existing vault directory.
    ///
    /// - Parameter vaultURL: Absolute URL of the vault root.
    /// - Throws: `VaultError.vaultNotFound(path:)` if the directory does not exist.
    ///   Does not create the vault; call `VaultLayout.createVaultLayout(at:)` first
    ///   when initializing a fresh vault.
    public init(vaultURL: URL) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: vaultURL.path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            throw VaultError.vaultNotFound(path: vaultURL)
        }
        self.vaultURL = vaultURL
    }

    /// Lists every scope in the vault, sorted by identity.
    ///
    /// A subdirectory of `scopes/` counts as a scope only if it contains a readable
    /// `scope.yaml`. Directories without one are silently skipped so partial writes
    /// during development don't crash surface-level enumeration.
    public func listScopes() throws -> [ScopeMetadata] {
        let scopesRoot = VaultLayout.scopesDirectoryURL(in: vaultURL)
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: scopesRoot.path) {
            return []
        }

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: scopesRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw VaultError.fileSystemError(path: scopesRoot, underlying: error)
        }

        var scopes: [ScopeMetadata] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            let yamlURL = VaultLayout.scopeYAMLURL(entry.lastPathComponent, in: vaultURL)
            guard fileManager.fileExists(atPath: yamlURL.path) else { continue }
            scopes.append(try decodeScopeYAML(at: yamlURL))
        }
        return scopes.sorted { $0.identity < $1.identity }
    }

    /// Lists every shared entry ID, sorted alphabetically.
    ///
    /// Returns the filename stem (without `.age`) of each file in `shared/`.
    public func listShared() throws -> [String] {
        let sharedRoot = VaultLayout.sharedDirectoryURL(in: vaultURL)
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: sharedRoot.path) {
            return []
        }

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: sharedRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw VaultError.fileSystemError(path: sharedRoot, underlying: error)
        }

        let stems =
            entries
            .filter { $0.pathExtension == "age" }
            .map { $0.deletingPathExtension().lastPathComponent }
        return stems.sorted()
    }

    /// Loads the metadata for a single scope.
    ///
    /// - Parameter id: Scope identifier (matches the directory name).
    /// - Returns: The decoded `ScopeMetadata`.
    /// - Throws: `VaultError.scopeNotFound(id:)` if the scope directory or its
    ///   `scope.yaml` is missing; `VaultError.yamlDecodeError` if decoding fails.
    public func getScope(_ id: String) throws -> ScopeMetadata {
        let yamlURL = VaultLayout.scopeYAMLURL(id, in: vaultURL)
        guard FileManager.default.fileExists(atPath: yamlURL.path) else {
            throw VaultError.scopeNotFound(id: id)
        }
        return try decodeScopeYAML(at: yamlURL)
    }

    /// Enumerates a scope's secrets without decrypting.
    ///
    /// Returns one `SecretInfo` per `.age` or `.link` file in the scope directory
    /// (`scope.yaml` excluded). Results are sorted by key.
    public func inspect(_ scopeID: String) throws -> [SecretInfo] {
        let scopeDir = VaultLayout.scopeDirectoryURL(scopeID, in: vaultURL)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: scopeDir.path) else {
            throw VaultError.scopeNotFound(id: scopeID)
        }

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: scopeDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw VaultError.fileSystemError(path: scopeDir, underlying: error)
        }

        var infos: [SecretInfo] = []
        for entry in entries {
            let key = entry.deletingPathExtension().lastPathComponent
            switch entry.pathExtension {
            case "age":
                infos.append(SecretInfo(key: key, kind: .value))
            case "link":
                let sharedID = try readLinkTarget(at: entry)
                infos.append(SecretInfo(key: key, kind: .link(sharedID: sharedID)))
            default:
                continue
            }
        }
        return infos.sorted { $0.key < $1.key }
    }

    /// Creates a link from a scope key to a shared entry.
    ///
    /// Writes `<key>.link` containing the shared entry ID and removes any
    /// pre-existing `<key>.age` for the same key (a scope key is either a
    /// direct value or a link, never both).
    ///
    /// - Throws: `VaultError.scopeNotFound(id:)` if the scope directory is absent.
    public func link(_ key: String, inScope scopeID: String, toShared sharedID: String) throws {
        let scopeDir = VaultLayout.scopeDirectoryURL(scopeID, in: vaultURL)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: scopeDir.path) else {
            throw VaultError.scopeNotFound(id: scopeID)
        }

        let linkURL = VaultLayout.linkURL(key, inScope: scopeID, in: vaultURL)
        do {
            try sharedID.write(to: linkURL, atomically: true, encoding: .utf8)
        } catch {
            throw VaultError.fileSystemError(path: linkURL, underlying: error)
        }

        let ageURL = VaultLayout.secretURL(key, inScope: scopeID, in: vaultURL)
        if fileManager.fileExists(atPath: ageURL.path) {
            do {
                try fileManager.removeItem(at: ageURL)
            } catch {
                throw VaultError.fileSystemError(path: ageURL, underlying: error)
            }
        }
    }

    /// Builds the vault-wide link graph: shared entry ID → referencing (scope, key) pairs.
    ///
    /// Walks every `scopes/*/*.link` file. Shared entries with no `.link` references
    /// simply don't appear as keys in the returned dictionary.
    public func linkGraph() throws -> [String: [(scopeID: String, key: String)]] {
        let scopesRoot = VaultLayout.scopesDirectoryURL(in: vaultURL)
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: scopesRoot.path) {
            return [:]
        }

        let scopeDirs: [URL]
        do {
            scopeDirs = try fileManager.contentsOfDirectory(
                at: scopesRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw VaultError.fileSystemError(path: scopesRoot, underlying: error)
        }

        var graph: [String: [(scopeID: String, key: String)]] = [:]
        for scopeDir in scopeDirs {
            let values = try? scopeDir.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            let scopeID = scopeDir.lastPathComponent

            let entries: [URL]
            do {
                entries = try fileManager.contentsOfDirectory(
                    at: scopeDir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
            } catch {
                throw VaultError.fileSystemError(path: scopeDir, underlying: error)
            }

            for entry in entries where entry.pathExtension == "link" {
                let key = entry.deletingPathExtension().lastPathComponent
                let sharedID = try readLinkTarget(at: entry)
                graph[sharedID, default: []].append((scopeID: scopeID, key: key))
            }
        }
        return graph
    }

    /// Returns shared entry IDs that no scope links to, sorted alphabetically.
    ///
    /// Useful for cleanup surfaces: a shared entry that no `.link` file references
    /// is a candidate for removal.
    public func orphanedSharedEntries() throws -> [String] {
        let shared = try listShared()
        let referenced = Set(try linkGraph().keys)
        return shared.filter { !referenced.contains($0) }.sorted()
    }

    // MARK: - Private helpers

    /// Decodes a scope's YAML file into `ScopeMetadata`, mapping errors to `VaultError`.
    private func decodeScopeYAML(at url: URL) throws -> ScopeMetadata {
        let contents: String
        do {
            contents = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw VaultError.fileSystemError(path: url, underlying: error)
        }
        do {
            return try YAMLDecoder().decode(ScopeMetadata.self, from: contents)
        } catch {
            throw VaultError.yamlDecodeError(path: url, underlying: error)
        }
    }

    /// Reads a `.link` file's shared-entry-ID payload, trimming surrounding whitespace.
    private func readLinkTarget(at url: URL) throws -> String {
        let raw: String
        do {
            raw = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw VaultError.fileSystemError(path: url, underlying: error)
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
