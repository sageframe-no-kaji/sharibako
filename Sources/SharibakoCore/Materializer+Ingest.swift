import Foundation

/// Read-path operations for ``Materializer`` — the ingest/accept/update cycle
/// that turns a directory with `.env`-family files into a scope and pushes
/// hand-edited file values back into the vault.
///
/// Kept in an extension file matching the AT-01 write-path split: the type
/// declaration and marker/scan/materialize/clean/heal live in `Materializer.swift`;
/// the ingest/update work lives here.
extension Materializer {
    /// Reads `.env`/`.env.local`/`.env.example` in `directory` and proposes a scope.
    ///
    /// Merges `.env` (base) with `.env.local` (overrides), collects `.env.example`
    /// keys that neither concrete file provides, suggests a scope ID with
    /// vault-side collision avoidance, and marks any detected key whose name
    /// exactly matches a shared entry. Detected keys carry non-empty merged
    /// values; a key whose merged value is empty joins
    /// ``ProposedScope/suggestedKeysNeedingValues`` instead — an empty string is
    /// never a secret worth importing (ho-04.10).
    ///
    /// Writes nothing — neither vault nor marker. Callers pair with
    /// ``acceptIngest(_:decisions:scopeID:scopeType:)`` to commit the decisions.
    public func ingest(directory: URL) throws -> ProposedScope {
        let suggestedScopeID = try suggestScopeID(fromDirectoryName: directory.lastPathComponent)
        let sharedIDs = Set(try vaultCore.listShared())

        var envMerged: [MergedEntry] = []
        var envKeyIndex: [String: Int] = [:]
        var warnings: [ParseWarning] = []

        let envURL = directory.appendingPathComponent(".env")
        let envLocalURL = directory.appendingPathComponent(".env.local")
        let envExampleURL = directory.appendingPathComponent(".env.example")

        try readAndMerge(fileURL: envURL, into: &envMerged, index: &envKeyIndex, warnings: &warnings)
        try readAndMerge(fileURL: envLocalURL, into: &envMerged, index: &envKeyIndex, warnings: &warnings)

        let detectedKeys = envMerged.compactMap { entry -> DetectedKey? in
            guard !entry.value.isEmpty else { return nil }
            return DetectedKey(
                key: entry.key,
                value: entry.value,
                sourceFile: entry.sourceFile,
                nameMatchedSharedID: sharedIDs.contains(entry.key) ? entry.key : nil
            )
        }

        // Empty-valued keys (`KEY=`) need a value, same as .env.example-only keys.
        var suggestedKeysNeedingValues = envMerged.filter(\.value.isEmpty).map(\.key)
        if let example = try readParseIfExists(fileURL: envExampleURL, warnings: &warnings) {
            for line in example.lines {
                if case .keyValue(let key, _, _) = line, envKeyIndex[key] == nil {
                    suggestedKeysNeedingValues.append(key)
                }
            }
        }

        return ProposedScope(
            directory: directory,
            suggestedScopeID: suggestedScopeID,
            suggestedScopeType: .projectDev,
            detectedKeys: detectedKeys,
            suggestedKeysNeedingValues: suggestedKeysNeedingValues.sorted(),
            parseWarnings: warnings
        )
    }

    /// Routes each ``KeyDecision`` to the correct ``VaultCore`` write and drops
    /// the `.sharibako` marker.
    ///
    /// Every decision's key must match a detected key in the proposal; unknown
    /// keys throw ``VaultError/ingestKeyMismatch(unknownKey:)``. The scope is
    /// created idempotently — if the vault already has a scope with the resolved
    /// ID, the operation reuses it (the existing scope's type wins; no rewrite).
    ///
    /// - Parameters:
    ///   - proposal: The proposal from ``ingest(directory:)``.
    ///   - decisions: Per-key routing.
    ///   - scopeID: Optional override; defaults to `proposal.suggestedScopeID`.
    ///   - scopeType: Optional override; defaults to `proposal.suggestedScopeType`.
    /// - Throws: `VaultError` cases as raised by the underlying `VaultCore` calls,
    ///   plus ``VaultError/ingestKeyMismatch(unknownKey:)``.
    public func acceptIngest(
        _ proposal: ProposedScope,
        decisions: [KeyDecision],
        scopeID: String? = nil,
        scopeType: ScopeType? = nil
    ) throws {
        let resolvedScopeID = scopeID ?? proposal.suggestedScopeID
        let resolvedScopeType = scopeType ?? proposal.suggestedScopeType

        var detectedByKey: [String: DetectedKey] = [:]
        for detected in proposal.detectedKeys {
            detectedByKey[detected.key] = detected
        }
        // Validate every decision up-front against the proposal's detected keys,
        // and pair each with its DetectedKey so `apply` receives a non-Optional value.
        let plan: [(KeyDecision, DetectedKey)] = try decisions.map { decision in
            let key = keyName(of: decision)
            guard let detected = detectedByKey[key] else {
                throw VaultError.ingestKeyMismatch(unknownKey: key)
            }
            return (decision, detected)
        }

        try ensureScopeExists(scopeID: resolvedScopeID, type: resolvedScopeType)

        for (decision, detected) in plan {
            try apply(decision: decision, scopeID: resolvedScopeID, detected: detected)
        }

        let markerURL = proposal.directory.appendingPathComponent(".sharibako")
        let marker = ScopeMarker(scope: resolvedScopeID, materializeTo: nil, markerURL: markerURL)
        try writeMarker(marker, at: markerURL)
    }

    /// Reads the target file, compares each owned key's file value to the vault
    /// value, and rewrites the vault for keys that drifted.
    ///
    /// Non-owned lines are invisible — their values are never read. When a key
    /// appears twice the last occurrence wins (ho-04.10), so a correction
    /// appended at the bottom of the file is what lands in the vault. Owned keys
    /// absent from the file are not reported as updates (removal is a `heal`
    /// concern, not `update`'s), and an owned key whose line is malformed has no
    /// readable value to push — the parse warning carries the diagnosis.
    /// Idempotent: a repeat call after a successful `update` returns
    /// ``UpdateResult/noChanges(warnings:)``.
    public func update(scopeID: String, marker: ScopeMarker) throws -> UpdateResult {
        let targetURL = try marker.validatedTargetURL()
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: targetURL.path) else {
            return .fileMissing(path: targetURL)
        }
        let parseResult: ParseResult
        do {
            parseResult = try parseEnvFile(at: targetURL)
        } catch {
            throw error
        }

        let ownedInfos = try vaultCore.inspect(scopeID)
        // A key can hold BOTH <key>.age and <key>.link (addSecret documents
        // that it does not delete a pre-existing link; a crash inside link()
        // or a git merge of two machines can also persist the pair). Resolve
        // the collision the way every read does — the link wins, matching
        // VaultCore's resolveSecretTarget precedence — instead of trapping in
        // Dictionary(uniqueKeysWithValues:).
        let ownedByKey = Dictionary(ownedInfos.map { ($0.key, $0) }) { first, second in
            if case .link = first.kind { return first }
            return second
        }
        let fileValues = extractOwnedFileValues(
            from: parseResult.lines, ownedKeys: Set(ownedByKey.keys)
        )

        var keysUpdated: [String] = []
        for (key, fileValue) in fileValues {
            guard let info = ownedByKey[key] else { continue }
            let vaultValue = try vaultCore.getValue(key, inScope: scopeID)
            if fileValue == vaultValue { continue }
            try rotateOwned(info: info, scopeID: scopeID, newValue: fileValue)
            keysUpdated.append(key)
        }
        keysUpdated.sort()

        if keysUpdated.isEmpty {
            return .noChanges(warnings: parseResult.warnings)
        }
        return .updated(keysUpdated: keysUpdated, warnings: parseResult.warnings)
    }

    // MARK: - Private helpers

    /// Row in the ingest-time merge table — one per unique detected key.
    private struct MergedEntry {
        var key: String
        var value: String
        var sourceFile: URL
    }

    private func readAndMerge(
        fileURL: URL,
        into merged: inout [MergedEntry],
        index: inout [String: Int],
        warnings: inout [ParseWarning]
    ) throws {
        guard let parsed = try readParseIfExists(fileURL: fileURL, warnings: &warnings) else {
            return
        }
        for line in parsed.lines {
            guard case .keyValue(let key, let value, _) = line else { continue }
            if let existingIndex = index[key] {
                merged[existingIndex].value = value
                merged[existingIndex].sourceFile = fileURL
            } else {
                index[key] = merged.count
                merged.append(MergedEntry(key: key, value: value, sourceFile: fileURL))
            }
        }
    }

    private func readParseIfExists(
        fileURL: URL,
        warnings: inout [ParseWarning]
    ) throws -> ParseResult? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let parsed = try parseEnvFile(at: fileURL)
        warnings.append(contentsOf: parsed.warnings)
        return parsed
    }

    /// Sanitizes a directory basename to a scope ID, then walks around vault
    /// collisions with `-dev`, `-dev-2`, `-dev-3`, ….
    private func suggestScopeID(fromDirectoryName raw: String) throws -> String {
        let sanitized = sanitizeScopeID(raw)
        let existing = Set(try vaultCore.listScopes().map(\.identity))
        if !existing.contains(sanitized) { return sanitized }
        let devCandidate = "\(sanitized)-dev"
        if !existing.contains(devCandidate) { return devCandidate }
        var suffix = 2
        while existing.contains("\(sanitized)-dev-\(suffix)") {
            suffix += 1
        }
        return "\(sanitized)-dev-\(suffix)"
    }

    /// Sanitizes a raw directory-name string into a scope-ID candidate.
    ///
    /// Lowercases; replaces non-`[a-z0-9-]` with `-`; collapses runs of `-`;
    /// trims leading/trailing `-`. Falls back to `"scope"` on empty output.
    private func sanitizeScopeID(_ raw: String) -> String {
        let lower = raw.lowercased()
        var mapped = ""
        for scalar in lower.unicodeScalars {
            let isLower = scalar.value >= 0x61 && scalar.value <= 0x7A
            let isDigit = scalar.value >= 0x30 && scalar.value <= 0x39
            let isDash = scalar.value == 0x2D
            if isLower || isDigit || isDash {
                mapped.unicodeScalars.append(scalar)
            } else {
                mapped.append("-")
            }
        }
        var collapsed = ""
        var lastWasDash = false
        for char in mapped {
            if char == "-" {
                if lastWasDash { continue }
                lastWasDash = true
            } else {
                lastWasDash = false
            }
            collapsed.append(char)
        }
        while collapsed.hasPrefix("-") { collapsed.removeFirst() }
        while collapsed.hasSuffix("-") { collapsed.removeLast() }
        return collapsed.isEmpty ? "scope" : collapsed
    }

    private func keyName(of decision: KeyDecision) -> String {
        switch decision {
        case .importAsLocal(let key),
            .linkToShared(let key, _),
            .moveToShared(let key, _),
            .leaveAlone(let key),
            .skip(let key):
            return key
        }
    }

    private func ensureScopeExists(scopeID: String, type: ScopeType) throws {
        let existing = try vaultCore.listScopes().map(\.identity)
        if existing.contains(scopeID) { return }
        try vaultCore.createScope(scopeID, type: type)
    }

    private func apply(
        decision: KeyDecision,
        scopeID: String,
        detected: DetectedKey
    ) throws {
        switch decision {
        case .importAsLocal(let key):
            try vaultCore.addSecret(key, value: detected.value, inScope: scopeID)
        case .linkToShared(let key, let sharedID):
            let sharedIDs = Set(try vaultCore.listShared())
            guard sharedIDs.contains(sharedID) else {
                throw VaultError.sharedEntryNotFound(id: sharedID)
            }
            try vaultCore.link(key, inScope: scopeID, toShared: sharedID)
        case .moveToShared(let key, let newSharedID):
            try vaultCore.addSharedEntry(newSharedID, value: detected.value)
            try vaultCore.link(key, inScope: scopeID, toShared: newSharedID)
        case .leaveAlone, .skip:
            break
        }
    }

    private func rotateOwned(info: SecretInfo, scopeID: String, newValue: String) throws {
        switch info.kind {
        case .value:
            try vaultCore.rotate(info.key, inScope: scopeID, newValue: newValue)
        case .link(let sharedID):
            try vaultCore.rotateShared(sharedID, newValue: newValue)
        }
    }
}
