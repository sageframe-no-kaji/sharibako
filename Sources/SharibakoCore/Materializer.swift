import CryptoKit
import Foundation
import Yams

/// Bridge between the vault and the user's filesystem.
///
/// `Materializer` is a value type parallel to ``VaultCore`` and ``Conduit``. It reads
/// and writes `.sharibako` markers, walks scan roots looking for markers, and merges
/// a scope's owned key values into the target `.env` file — preserving non-owned
/// lines byte-for-byte per the kamae-2.2 ownership contract.
///
/// AT-01 covers the write path: markers, scan, status, materialize, clean, heal.
/// AT-02 will add ingest and update on top of the same type.
public struct Materializer: Sendable {
    /// The vault this materializer bridges.
    public let vaultCore: VaultCore

    /// Absolute URL of the vault root (redundant with `vaultCore.vaultURL`, kept
    /// for interface parity with ``Conduit`` and to make the bridge's identity explicit).
    public let vaultURL: URL

    /// Binds to a vault and its URL.
    ///
    /// Performs no I/O; a fresh `Materializer` doesn't verify the vault or check for
    /// any markers on disk. Downstream operations surface the specific failure they hit.
    public init(vaultCore: VaultCore, vaultURL: URL) {
        self.vaultCore = vaultCore
        self.vaultURL = vaultURL
    }
}

// MARK: - Marker load/write/resolve

extension Materializer {
    /// Loads a marker from a specific `.sharibako` file.
    ///
    /// Decodes YAML via Yams, then attaches the on-disk path so ``ScopeMarker/targetURL``
    /// resolves correctly. Rejects markers with an empty `scope` field or a
    /// `materialize_to` value that begins with `~` (breaks portability across machines).
    ///
    /// - Throws: ``VaultError/markerNotFound(startingFrom:)`` if the file does not exist;
    ///   ``VaultError/markerMalformed(path:reason:)`` if the YAML is invalid or missing
    ///   required fields; ``VaultError/fileSystemError(path:underlying:)`` on IO failure.
    public func loadMarker(at path: URL) throws -> ScopeMarker {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path.path) else {
            throw VaultError.markerNotFound(startingFrom: path)
        }
        let contents: String
        do {
            contents = try String(contentsOf: path, encoding: .utf8)
        } catch {
            throw VaultError.fileSystemError(path: path, underlying: error)
        }
        let decoded: ScopeMarker
        do {
            decoded = try YAMLDecoder().decode(ScopeMarker.self, from: contents)
        } catch {
            throw VaultError.markerMalformed(path: path, reason: "\(error)")
        }
        guard !decoded.scope.isEmpty else {
            throw VaultError.markerMalformed(path: path, reason: "'scope' field is empty")
        }
        if let materializeTo = decoded.materializeTo, materializeTo.hasPrefix("~") {
            throw VaultError.markerMalformed(
                path: path,
                reason: "'materialize_to' must not begin with '~' — markers must be portable across machines"
            )
        }
        return decoded.withMarkerURL(path)
    }

    /// Writes a marker to a specific path atomically.
    ///
    /// Encodes YAML via Yams; only ``ScopeMarker/scope`` and ``ScopeMarker/materializeTo``
    /// are emitted — ``ScopeMarker/markerURL`` is a runtime property, not part of the file.
    ///
    /// - Throws: ``VaultError/yamlEncodeError(path:underlying:)`` if YAML encoding fails;
    ///   ``VaultError/fileSystemError(path:underlying:)`` on IO failure.
    public func writeMarker(_ marker: ScopeMarker, at path: URL) throws {
        let yaml: String
        do {
            yaml = try YAMLEncoder().encode(marker)
        } catch {
            throw VaultError.yamlEncodeError(path: path, underlying: error)
        }
        do {
            try yaml.write(to: path, atomically: true, encoding: .utf8)
        } catch {
            throw VaultError.fileSystemError(path: path, underlying: error)
        }
    }

    /// Walks up from `startingFrom` looking for a `.sharibako` file.
    ///
    /// Stops at the user's home directory or the filesystem root, whichever comes first.
    /// Mirrors git's `.git/` discovery.
    ///
    /// - Throws: ``VaultError/markerNotFound(startingFrom:)`` if no marker is found.
    public func resolveMarker(startingFrom: URL) throws -> ScopeMarker {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL
        var current = startingFrom.standardizedFileURL
        while true {
            let candidate = current.appendingPathComponent(".sharibako")
            if fileManager.fileExists(atPath: candidate.path) {
                return try loadMarker(at: candidate)
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if current == home || parent == current {
                throw VaultError.markerNotFound(startingFrom: startingFrom)
            }
            current = parent
        }
    }

    /// Locates the marker whose `scope` field matches `scopeID` inside `scanRoots`.
    ///
    /// - Throws: ``VaultError/markerNotFound(startingFrom:)`` if no matching marker exists.
    public func resolveMarker(forScope scopeID: String, scanRoots: [URL]) throws -> ScopeMarker {
        let markers = try scan(roots: scanRoots)
        if let match = markers.first(where: { $0.scope == scopeID }) {
            return match
        }
        let hint = scanRoots.first ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        throw VaultError.markerNotFound(startingFrom: hint)
    }
}

// MARK: - Scan and status

extension Materializer {
    /// Walks `roots` recursively and returns every `.sharibako` marker found.
    ///
    /// Results are ordered breadth-first from each root, alphabetical within a depth,
    /// deduplicated by absolute path when roots overlap.
    public func scan(roots: [URL]) throws -> [ScopeMarker] {
        let fileManager = FileManager.default
        var seen = Set<String>()
        var results: [ScopeMarker] = []
        for root in roots {
            guard fileManager.fileExists(atPath: root.path) else { continue }
            let markerURLs = enumerateMarkerFiles(under: root)
            for url in markerURLs {
                let standardized = url.standardizedFileURL.path
                if seen.contains(standardized) { continue }
                seen.insert(standardized)
                results.append(try loadMarker(at: url))
            }
        }
        return results
    }

    /// Reports where the scope lives from this machine's perspective.
    ///
    /// - Throws: ``VaultError/scopeNotFound(id:)`` if neither the vault nor any marker
    ///   knows about the scope; other `VaultError` cases for underlying failures.
    public func status(scopeID: String, scanRoots: [URL]) throws -> ScopeState {
        let allScopes = try vaultCore.listScopes()
        let hasScope = allScopes.contains { $0.identity == scopeID }
        let markers = try scan(roots: scanRoots)
        let matchingMarker = markers.first { $0.scope == scopeID }
        if hasScope {
            if let marker = matchingMarker {
                return .liveHere(markerURL: marker.markerURL, targetURL: marker.targetURL)
            }
            return .liveElsewhere
        }
        if let marker = matchingMarker {
            return .orphaned(
                markerURL: marker.markerURL,
                reason: "vault has no scope named '\(scopeID)'"
            )
        }
        throw VaultError.scopeNotFound(id: scopeID)
    }

    /// Recursive enumeration of `.sharibako` regular files below `root`, ordered
    /// breadth-first / alphabetical.
    private func enumerateMarkerFiles(under root: URL) -> [URL] {
        let fileManager = FileManager.default
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: []
            )
        else {
            return []
        }
        var found: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == ".sharibako" {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                found.append(url)
            }
        }
        found.sort { lhs, rhs in
            let lhsDepth = lhs.pathComponents.count
            let rhsDepth = rhs.pathComponents.count
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            return lhs.path < rhs.path
        }
        return found
    }
}

// MARK: - Materialize

extension Materializer {
    /// Merges the scope's owned key values into the marker's target file.
    ///
    /// Non-owned lines pass through byte-for-byte. Owned lines are rewritten canonically.
    /// If the file has diverged on owned keys and `overwriteDrift` is `false`, returns
    /// ``MaterializeResult/diffPending(diff:)`` without writing.
    public func materialize(
        marker: ScopeMarker,
        overwriteDrift: Bool = false
    ) throws -> MaterializeResult {
        let scopeID = marker.scope
        let targetURL = marker.targetURL
        let readResult = try readAndParseTarget(at: targetURL)
        let originalText = readResult.originalText
        let parseResult = readResult.parseResult
        let fileExists = readResult.fileExists

        let ownedInfos = try vaultCore.inspect(scopeID)
        let ownedKeys = Set(ownedInfos.map(\.key))
        let vaultValues = try loadVaultValues(for: ownedInfos, inScope: scopeID)
        let fileValues = extractFirstFileValues(from: parseResult.lines, ownedKeys: ownedKeys)

        let (differing, missing) = computeDrift(
            ownedKeys: ownedKeys,
            fileValues: fileValues,
            vaultValues: vaultValues
        )
        if !differing.isEmpty, !overwriteDrift {
            return .diffPending(
                diff: MaterializeDiff(
                    scopeID: scopeID,
                    path: targetURL,
                    ownedKeysDiffering: differing,
                    ownedKeysMissingFromFile: missing
                )
            )
        }

        let outputLines = buildMaterializedLines(
            from: parseResult.lines,
            ownedKeys: ownedKeys,
            vaultValues: vaultValues,
            missingKeys: missing
        )
        let withTrailing = fileExists ? parseResult.hadTrailingNewline : true
        let renderedText = renderEnvLines(outputLines, withTrailingNewline: withTrailing)

        if fileExists, renderedText == originalText {
            return .unchanged(path: targetURL)
        }
        try writeAtomically(text: renderedText, to: targetURL)
        return .wrote(
            path: targetURL,
            keysWritten: collectOwnedKeysInLines(outputLines, ownedKeys: ownedKeys).sorted()
        )
    }

    /// Bundle returned by ``readAndParseTarget(at:)`` — original bytes, parse result,
    /// and whether the file actually exists on disk.
    private struct ReadResult {
        let originalText: String
        let parseResult: ParseResult
        let fileExists: Bool
    }

    /// Reads and parses the target file, returning empty results when it doesn't exist.
    private func readAndParseTarget(at url: URL) throws -> ReadResult {
        let fileManager = FileManager.default
        let exists = fileManager.fileExists(atPath: url.path)
        guard exists else {
            return ReadResult(
                originalText: "",
                parseResult: ParseResult(lines: [], warnings: [], hadTrailingNewline: false),
                fileExists: false
            )
        }
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw VaultError.fileSystemError(path: url, underlying: error)
        }
        return ReadResult(
            originalText: text,
            parseResult: parseEnvString(text, sourceFile: url),
            fileExists: true
        )
    }

    /// Decrypts and collects vault values for every owned info.
    private func loadVaultValues(
        for infos: [SecretInfo],
        inScope scopeID: String
    ) throws -> [String: String] {
        var values: [String: String] = [:]
        for info in infos {
            values[info.key] = try vaultCore.getValue(info.key, inScope: scopeID)
        }
        return values
    }

    /// Records the first parsed value for each owned key in the file.
    private func extractFirstFileValues(
        from lines: [EnvLine],
        ownedKeys: Set<String>
    ) -> [String: String] {
        var values: [String: String] = [:]
        for line in lines {
            guard case .keyValue(let key, let value, _) = line, ownedKeys.contains(key) else {
                continue
            }
            if values[key] == nil { values[key] = value }
        }
        return values
    }

    /// Sorted lists of owned keys that differ between file and vault, and owned keys
    /// entirely absent from the file.
    private func computeDrift(
        ownedKeys: Set<String>,
        fileValues: [String: String],
        vaultValues: [String: String]
    ) -> (differing: [String], missing: [String]) {
        var differing: [String] = []
        var missing: [String] = []
        for key in ownedKeys.sorted() {
            if let fileValue = fileValues[key] {
                if fileValue != vaultValues[key] {
                    differing.append(key)
                }
            } else {
                missing.append(key)
            }
        }
        return (differing, missing)
    }

    /// Builds the output line list by rewriting the first occurrence of each owned key
    /// canonically, dropping subsequent duplicates, and appending any missing owned keys.
    private func buildMaterializedLines(
        from lines: [EnvLine],
        ownedKeys: Set<String>,
        vaultValues: [String: String],
        missingKeys: [String]
    ) -> [EnvLine] {
        var output: [EnvLine] = []
        var replaced = Set<String>()
        for line in lines {
            if case .keyValue(let key, _, _) = line, ownedKeys.contains(key) {
                if replaced.contains(key) { continue }
                let vaultValue = vaultValues[key] ?? ""
                let rewrite = canonicalizeEnvLine(key: key, value: vaultValue)
                output.append(.keyValue(key: key, value: vaultValue, rawText: rewrite))
                replaced.insert(key)
            } else {
                output.append(line)
            }
        }
        appendMissingKeys(missingKeys, into: &output, vaultValues: vaultValues)
        return output
    }

    /// Appends new owned-key lines to the output.
    ///
    /// Inserts before a trailing blank line when present so the file's
    /// trailing-newline shape is preserved.
    private func appendMissingKeys(
        _ missing: [String],
        into output: inout [EnvLine],
        vaultValues: [String: String]
    ) {
        guard !missing.isEmpty else { return }
        let trailingBlank: EnvLine?
        if let last = output.last, case .blank = last {
            trailingBlank = output.removeLast()
        } else {
            trailingBlank = nil
            if !output.isEmpty {
                output.append(.blank(text: ""))
            }
        }
        for key in missing {
            let value = vaultValues[key] ?? ""
            let text = canonicalizeEnvLine(key: key, value: value)
            output.append(.keyValue(key: key, value: value, rawText: text))
        }
        if let trailing = trailingBlank {
            output.append(trailing)
        }
    }

    /// Set of owned keys represented as `.keyValue` in `lines`.
    private func collectOwnedKeysInLines(
        _ lines: [EnvLine],
        ownedKeys: Set<String>
    ) -> Set<String> {
        var found = Set<String>()
        for line in lines {
            if case .keyValue(let key, _, _) = line, ownedKeys.contains(key) {
                found.insert(key)
            }
        }
        return found
    }

    /// Writes `text` atomically, creating the parent directory when necessary.
    private func writeAtomically(text: String, to url: URL) throws {
        let fileManager = FileManager.default
        let parent = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            do {
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            } catch {
                throw VaultError.fileSystemError(path: parent, underlying: error)
            }
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw VaultError.fileSystemError(path: url, underlying: error)
        }
    }
}

// MARK: - Clean and heal

extension Materializer {
    /// Removes the scope's owned lines from the target file.
    ///
    /// Non-owned lines (blanks, comments, malformed, non-owned key/value pairs) are
    /// preserved. Deletes the file when nothing but blanks and comments remain.
    public func clean(marker: ScopeMarker) throws -> CleanResult {
        let scopeID = marker.scope
        let targetURL = marker.targetURL
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: targetURL.path) else {
            return .fileMissing(path: targetURL)
        }
        let text: String
        do {
            text = try String(contentsOf: targetURL, encoding: .utf8)
        } catch {
            throw VaultError.fileSystemError(path: targetURL, underlying: error)
        }
        let parseResult = parseEnvString(text, sourceFile: targetURL)
        let ownedKeys = Set(try vaultCore.inspect(scopeID).map(\.key))

        var removed = Set<String>()
        var filtered: [EnvLine] = []
        for line in parseResult.lines {
            if case .keyValue(let key, _, _) = line, ownedKeys.contains(key) {
                removed.insert(key)
                continue
            }
            filtered.append(line)
        }
        let sortedRemoved = removed.sorted()

        let hasSubstantive = filtered.contains { line in
            switch line {
            case .keyValue, .malformed: return true
            case .blank, .comment: return false
            }
        }
        if !hasSubstantive {
            do {
                try fileManager.removeItem(at: targetURL)
            } catch {
                throw VaultError.fileSystemError(path: targetURL, underlying: error)
            }
            return .cleaned(path: targetURL, keysRemoved: sortedRemoved, fileStillExists: false)
        }
        let output = renderEnvLines(filtered, withTrailingNewline: parseResult.hadTrailingNewline)
        try writeAtomically(text: output, to: targetURL)
        return .cleaned(path: targetURL, keysRemoved: sortedRemoved, fileStillExists: true)
    }

    /// Reports drift between the vault and the target file for each owned key.
    ///
    /// Non-owned lines are invisible to `heal`. When the file doesn't exist, every
    /// owned key is reported as ``KeyDrift/fileMissing(key:)``.
    public func heal(marker: ScopeMarker) throws -> DriftReport {
        let scopeID = marker.scope
        let targetURL = marker.targetURL
        let fileManager = FileManager.default
        let ownedKeys = try vaultCore.inspect(scopeID).map(\.key).sorted()

        guard fileManager.fileExists(atPath: targetURL.path) else {
            let owned = ownedKeys.map { KeyDrift.fileMissing(key: $0) }
            return DriftReport(scopeID: scopeID, path: targetURL, owned: owned, parseWarnings: [])
        }
        let text: String
        do {
            text = try String(contentsOf: targetURL, encoding: .utf8)
        } catch {
            throw VaultError.fileSystemError(path: targetURL, underlying: error)
        }
        let parseResult = parseEnvString(text, sourceFile: targetURL)
        let ownedKeySet = Set(ownedKeys)
        let fileValues = extractFirstFileValues(from: parseResult.lines, ownedKeys: ownedKeySet)

        var vaultValues: [String: String] = [:]
        for key in ownedKeys {
            vaultValues[key] = try vaultCore.getValue(key, inScope: scopeID)
        }

        var drift: [KeyDrift] = []
        for key in ownedKeys {
            let vaultValue = vaultValues[key] ?? ""
            if let fileValue = fileValues[key] {
                if fileValue == vaultValue {
                    drift.append(.match(key: key))
                } else {
                    drift.append(
                        .fileValueDiffers(
                            key: key,
                            vaultSha256: sha256Hex(vaultValue),
                            fileSha256: sha256Hex(fileValue)
                        )
                    )
                }
            } else {
                drift.append(.fileMissing(key: key))
            }
        }
        return DriftReport(
            scopeID: scopeID,
            path: targetURL,
            owned: drift,
            parseWarnings: parseResult.warnings
        )
    }
}

/// Returns the SHA-256 hex digest of a string's UTF-8 bytes.
///
/// Used by ``Materializer/heal(marker:)`` to describe drift without surfacing plaintext.
internal func sha256Hex(_ text: String) -> String {
    let digest = SHA256.hash(data: Data(text.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}
