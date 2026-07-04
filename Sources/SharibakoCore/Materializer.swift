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
    /// resolves correctly. Markers sync via git, so both declared fields are
    /// untrusted input (ho-04.9): `scope` must satisfy the identifier grammar
    /// (it becomes a vault path component), and `materialize_to` must pass
    /// ``ScopeMarker/validatedTargetURL()``'s containment policy (relative,
    /// no `~`, resolves within the marker's directory subtree) so a crafted
    /// marker cannot aim `materialize`/`clean` outside the project.
    ///
    /// - Throws: ``VaultError/markerNotFound(startingFrom:)`` if the file does not exist;
    ///   ``VaultError/markerMalformed(path:reason:)`` if the YAML is invalid, missing
    ///   required fields, or fails validation; ``VaultError/fileSystemError(path:underlying:)``
    ///   on IO failure.
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
        guard VaultLayout.isValidIdentifier(decoded.scope) else {
            throw VaultError.markerMalformed(
                path: path,
                reason: "'scope' is not a valid identifier (got \"\(decoded.scope)\")"
            )
        }
        let marker = decoded.withMarkerURL(path)
        // Fail at load, not first write: a marker whose target escapes should
        // surface on scan/status, before anything acts on it.
        _ = try marker.validatedTargetURL()
        return marker
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
        let markers = try scan(roots: scanRoots).markers
        if let match = markers.first(where: { $0.scope == scopeID }) {
            return match
        }
        let hint = scanRoots.first ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        throw VaultError.markerNotFound(startingFrom: hint)
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
        let targetURL = try marker.validatedTargetURL()
        let readResult = try readAndParseTarget(at: targetURL)
        let originalText = readResult.originalText
        let parseResult = readResult.parseResult
        let fileExists = readResult.fileExists

        let ownedInfos = try vaultCore.inspect(scopeID)
        let ownedKeys = Set(ownedInfos.map(\.key))
        let vaultValues = try loadVaultValues(for: ownedInfos, inScope: scopeID)
        let fileValues = extractOwnedFileValues(from: parseResult.lines, ownedKeys: ownedKeys)
        let corruptedKeys = corruptedOwnedKeys(in: parseResult.lines, ownedKeys: ownedKeys)

        let (differing, missing) = computeDrift(
            ownedKeys: ownedKeys,
            fileValues: fileValues,
            vaultValues: vaultValues,
            corruptedKeys: corruptedKeys
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

        let withTrailing = fileExists ? parseResult.hadTrailingNewline : true
        let outputLines = buildMaterializedLines(
            from: parseResult.lines,
            ownedKeys: ownedKeys,
            vaultValues: vaultValues,
            missingKeys: missing,
            appendStyle: AppendStyle(
                crlf: dominantLineEndingIsCRLF(parseResult.lines),
                endsWithTerminator: withTrailing
            )
        )
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

    /// Records the parsed value for each owned key in the file — the last
    /// occurrence wins (ho-04.10), matching shell/compose read semantics and
    /// ingest's merge order.
    internal func extractOwnedFileValues(
        from lines: [EnvLine],
        ownedKeys: Set<String>
    ) -> [String: String] {
        var values: [String: String] = [:]
        for line in lines {
            guard case .keyValue(let key, let value, _) = line, ownedKeys.contains(key) else {
                continue
            }
            values[key] = value
        }
        return values
    }

    /// Owned keys whose file line is malformed.
    ///
    /// The line *intends* an owned key (`envLineIntendedKey`) but failed to
    /// parse. Corruption doesn't transfer ownership (ho-04.10): these count as
    /// drift, are rewritten in place by `materialize`, removed by `clean`, and
    /// reported by `heal`.
    internal func corruptedOwnedKeys(
        in lines: [EnvLine],
        ownedKeys: Set<String>
    ) -> Set<String> {
        var corrupted = Set<String>()
        for line in lines {
            guard case .malformed(let text, _) = line else { continue }
            if let key = envLineIntendedKey(text), ownedKeys.contains(key) {
                corrupted.insert(key)
            }
        }
        return corrupted
    }

    /// The owned key a line claims — a parsed key/value's key, or the intended
    /// key of a malformed line (a corrupted owned line, ho-04.10).
    private func ownedKeyClaimed(by line: EnvLine, ownedKeys: Set<String>) -> String? {
        switch line {
        case .keyValue(let key, _, _):
            return ownedKeys.contains(key) ? key : nil
        case .malformed(let text, _):
            guard let key = envLineIntendedKey(text), ownedKeys.contains(key) else { return nil }
            return key
        case .blank, .comment:
            return nil
        }
    }

    /// Sorted lists of owned keys that differ between file and vault, and owned keys
    /// entirely absent from the file.
    ///
    /// A corrupted owned line always counts as differing — its bytes are not the
    /// canonical line — so the `diffPending`/`overwriteDrift` gate protects a
    /// hand-edit in progress.
    private func computeDrift(
        ownedKeys: Set<String>,
        fileValues: [String: String],
        vaultValues: [String: String],
        corruptedKeys: Set<String>
    ) -> (differing: [String], missing: [String]) {
        var differing: [String] = []
        var missing: [String] = []
        for key in ownedKeys.sorted() {
            if corruptedKeys.contains(key) {
                differing.append(key)
            } else if let fileValue = fileValues[key] {
                if fileValue != vaultValues[key] {
                    differing.append(key)
                }
            } else {
                missing.append(key)
            }
        }
        return (differing, missing)
    }

    /// Terminator style for lines the materializer appends (ho-04.10).
    ///
    /// `crlf` mirrors the file's dominant line ending; `endsWithTerminator` is
    /// whether the render appends a final newline — a final line left
    /// unterminated must not end in a stray `\r`.
    private struct AppendStyle {
        let crlf: Bool
        let endsWithTerminator: Bool
    }

    /// Builds the output line list for a materialize write.
    ///
    /// Rewrites the first line each owned key claims — parsed or corrupted
    /// (ho-04.10) — canonically, drops subsequent claims, and appends any
    /// missing owned keys. Rewrites keep the terminator of the line they
    /// replace; appended lines follow `appendStyle`.
    private func buildMaterializedLines(
        from lines: [EnvLine],
        ownedKeys: Set<String>,
        vaultValues: [String: String],
        missingKeys: [String],
        appendStyle: AppendStyle
    ) -> [EnvLine] {
        var output: [EnvLine] = []
        var replaced = Set<String>()
        for line in lines {
            guard let key = ownedKeyClaimed(by: line, ownedKeys: ownedKeys) else {
                output.append(line)
                continue
            }
            if replaced.contains(key) { continue }
            let vaultValue = vaultValues[key] ?? ""
            var rewrite = canonicalizeEnvLine(key: key, value: vaultValue)
            if line.endsWithCR {
                rewrite += "\r"
            }
            output.append(.keyValue(key: key, value: vaultValue, rawText: rewrite))
            replaced.insert(key)
        }
        appendMissingKeys(missingKeys, into: &output, vaultValues: vaultValues, style: appendStyle)
        return output
    }

    /// Appends new owned-key lines to the output.
    ///
    /// Inserts before a trailing blank line when present so the file's
    /// trailing-newline shape is preserved. Appended lines carry a `\r` when
    /// the file is predominantly CRLF — except a final line the render leaves
    /// unterminated, which must not end in a stray `\r`.
    private func appendMissingKeys(
        _ missing: [String],
        into output: inout [EnvLine],
        vaultValues: [String: String],
        style: AppendStyle
    ) {
        guard !missing.isEmpty else { return }
        let eol = style.crlf ? "\r" : ""
        let trailingBlank: EnvLine?
        if let last = output.last, case .blank = last {
            trailingBlank = output.removeLast()
        } else {
            trailingBlank = nil
            if !output.isEmpty {
                output.append(.blank(text: eol))
            }
        }
        for key in missing {
            let value = vaultValues[key] ?? ""
            let text = canonicalizeEnvLine(key: key, value: value) + eol
            output.append(.keyValue(key: key, value: value, rawText: text))
        }
        if let trailing = trailingBlank {
            output.append(trailing)
        } else if style.crlf, !style.endsWithTerminator, let last = output.last, last.endsWithCR {
            output[output.count - 1] = last.removingCarriageReturn()
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

    /// Writes `text` atomically with owner-only (0600) permissions, creating
    /// the parent directory when necessary.
    ///
    /// Materialized targets hold decrypted secrets, so the permission bits are
    /// part of the write's contract (ho-04.8): the temp sibling is created
    /// 0600 BEFORE any plaintext lands in it — a chmod after `String.write`
    /// would leave a window where the plaintext sits at default permissions —
    /// and then renamed into place, which is atomic within one directory.
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
        let temp = parent.appendingPathComponent(
            ".\(url.lastPathComponent).sharibako-tmp-\(UUID().uuidString)",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: temp) }
        guard
            fileManager.createFile(
                atPath: temp.path,
                contents: Data(text.utf8),
                attributes: [.posixPermissions: 0o600]
            )
        else {
            throw VaultError.fileSystemError(path: temp, underlying: POSIXError(.EIO))
        }
        // POSIX rename(2): atomically creates-or-replaces the target. An
        // existing target's permission bits do not survive — 0600 is enforced
        // on every materialize, not just the first.
        let renameStatus = rename(
            fileManager.fileSystemRepresentation(withPath: temp.path),
            fileManager.fileSystemRepresentation(withPath: url.path)
        )
        guard renameStatus == 0 else {
            throw VaultError.fileSystemError(
                path: url,
                underlying: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            )
        }
    }
}

// MARK: - Clean and heal

extension Materializer {
    /// Removes the scope's owned lines from the target file.
    ///
    /// Non-owned lines (blanks, comments, malformed, non-owned key/value pairs) are
    /// preserved. A malformed line that *intends* an owned key is an owned line —
    /// corruption doesn't transfer ownership (ho-04.10) — and is removed with the
    /// rest. Deletes the file when nothing but blanks and comments remain.
    public func clean(marker: ScopeMarker) throws -> CleanResult {
        let scopeID = marker.scope
        let targetURL = try marker.validatedTargetURL()
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
            if let key = ownedKeyClaimed(by: line, ownedKeys: ownedKeys) {
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
    /// owned key is reported as ``KeyDrift/fileMissing(key:)``. An owned key whose
    /// file line is malformed reports ``KeyDrift/fileLineCorrupted(key:)`` — the
    /// value is unreadable, so there is nothing to hash (ho-04.10).
    public func heal(marker: ScopeMarker) throws -> DriftReport {
        let scopeID = marker.scope
        let targetURL = try marker.validatedTargetURL()
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
        let fileValues = extractOwnedFileValues(from: parseResult.lines, ownedKeys: ownedKeySet)
        let corruptedKeys = corruptedOwnedKeys(in: parseResult.lines, ownedKeys: ownedKeySet)

        var vaultValues: [String: String] = [:]
        for key in ownedKeys {
            vaultValues[key] = try vaultCore.getValue(key, inScope: scopeID)
        }

        var drift: [KeyDrift] = []
        for key in ownedKeys {
            let vaultValue = vaultValues[key] ?? ""
            if corruptedKeys.contains(key) {
                drift.append(.fileLineCorrupted(key: key))
            } else if let fileValue = fileValues[key] {
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
