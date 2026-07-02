import Foundation
import SharibakoCore

/// The TTY implementation of ``IngestDecisionSource``.
///
/// Walks each ``DetectedKey`` in the proposal through an ``InteractiveSelect``
/// prompt. When `nameMatchedSharedID` is set the cursor defaults to the
/// "link to shared" row. "Link to shared" triggers a second select over the
/// available shared IDs; "move to shared" prompts for a new slug via
/// `lineReader`.
///
/// All I/O seams are injectable so the branching logic can be tested
/// without a real terminal: inject `selectFactory` returning predetermined
/// indices and `lineReader` returning canned strings.
struct InteractiveIngestPrompt: IngestDecisionSource {
    /// Factory that drives one select prompt and returns the chosen index.
    ///
    /// Parameters: `(title, choices, initialIndex)`.
    /// Default runs a real ``InteractiveSelect``.
    /// Inject in tests to return a predetermined choice without a TTY.
    var selectFactory: (_ title: String, _ choices: [String], _ initialIndex: Int) throws -> Int = {
        try InteractiveSelect(title: $0, choices: $1, initialIndex: $2).run()
    }

    /// Line reader for the "move to shared" new-slug prompt.
    ///
    /// Defaults to `readLine()`. Inject in tests to supply canned input.
    var lineReader: () -> String? = { readLine() }

    /// Output sink for headers and info lines (not choice rendering).
    ///
    /// Defaults to `print`. Inject in tests to suppress or capture output.
    var print: (String) -> Void = { Swift.print($0) }

    // MARK: - IngestDecisionSource

    /// Walks each detected key through the five-choice prompt and returns decisions.
    func decisions(for proposal: ProposedScope, sharedIDs: [String]) throws -> [KeyDecision] {
        print("Scope: \(proposal.suggestedScopeID)  •  \(proposal.detectedKeys.count) key(s) detected")
        return try proposal.detectedKeys.map { detected in
            try promptDecision(for: detected, sharedIDs: sharedIDs)
        }
    }

    // MARK: - Private prompt logic

    private func promptDecision(for detected: DetectedKey, sharedIDs: [String]) throws -> KeyDecision {
        let fields = buildFields(for: detected, sharedIDs: sharedIDs)
        let defaultIndex = defaultFieldIndex(for: detected, fields: fields)
        let chosenIndex = try selectFactory(detected.key, fields.map(\.label), defaultIndex)
        let chosen = fields[chosenIndex]

        switch chosen {
        case .importAsLocal:
            return .importAsLocal(key: detected.key)

        case .linkToShared:
            return try resolveLink(for: detected, sharedIDs: sharedIDs)

        case .moveToShared:
            return try resolveMove(for: detected)

        case .leaveAlone:
            return .leaveAlone(key: detected.key)

        case .skip:
            return .skip(key: detected.key)
        }
    }

    /// Builds the ordered list of choice fields for one key.
    ///
    /// "Link to shared" is omitted when `sharedIDs` is empty (no targets).
    private func buildFields(for detected: DetectedKey, sharedIDs: [String]) -> [KeyDecisionField] {
        var fields: [KeyDecisionField] = [.importAsLocal]
        if !sharedIDs.isEmpty {
            fields.append(.linkToShared(matchedID: detected.nameMatchedSharedID))
        }
        fields.append(.moveToShared)
        fields.append(.leaveAlone)
        fields.append(.skip)
        return fields
    }

    /// Returns the index in `fields` that should be pre-highlighted.
    ///
    /// Defaults to "link to shared" when the key has a `nameMatchedSharedID`
    /// and shared entries are available; otherwise defaults to index 0
    /// ("import as scope-local").
    private func defaultFieldIndex(for detected: DetectedKey, fields: [KeyDecisionField]) -> Int {
        guard detected.nameMatchedSharedID != nil else { return 0 }
        return fields.firstIndex {
            if case .linkToShared = $0 { return true }
            return false
        } ?? 0
    }

    /// Resolves a "link to shared" choice: runs a second select over `sharedIDs`,
    /// defaulting the cursor to the name-matched entry when present.
    private func resolveLink(for detected: DetectedKey, sharedIDs: [String]) throws -> KeyDecision {
        let defaultSharedIndex =
            detected.nameMatchedSharedID.flatMap { id in
                sharedIDs.firstIndex(of: id)
            } ?? 0
        let sharedIndex = try selectFactory(
            "Link \(detected.key) to:",
            sharedIDs,
            defaultSharedIndex
        )
        return .linkToShared(key: detected.key, sharedID: sharedIDs[sharedIndex])
    }

    /// Resolves a "move to shared" choice: reads a new slug from `lineReader`
    /// and sanitizes it with the same rules the scope ID uses.
    private func resolveMove(for detected: DetectedKey) throws -> KeyDecision {
        print("New shared entry ID for \(detected.key):")
        let raw = lineReader() ?? ""
        let slug = sanitizeSharedID(raw)
        return .moveToShared(key: detected.key, newSharedID: slug)
    }
}

// MARK: - Slug sanitizer (local copy of Materializer's private sanitizeScopeID)
//
// Materializer.sanitizeScopeID is private. Duplicated here with the same
// rules so shared-entry IDs follow the same conventions as scope IDs.
// If the rules diverge in a future ho, factor a public helper on SharibakoCore.

private func sanitizeSharedID(_ raw: String) -> String {
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
