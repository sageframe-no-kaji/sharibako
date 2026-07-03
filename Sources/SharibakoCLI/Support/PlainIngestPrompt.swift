import Foundation
import SharibakoCore

/// The plain line-based implementation of ``IngestDecisionSource``.
///
/// Prints the detected keys, offers a one-keystroke "import all", and collects
/// per-key exceptions through simple line prompts. No raw mode, no full-screen
/// rendering — the idiomatic-CLI surface that supersedes ho-04.4's dashboard.
///
/// All I/O seams are injectable so the branching logic can be tested without a
/// terminal: inject `lineReader` to supply canned input and `print` to capture
/// output.
struct PlainIngestPrompt: IngestDecisionSource {
    /// Line reader for every prompt.
    ///
    /// Defaults to `readLine()`.
    var lineReader: () -> String? = { readLine() }

    /// Output sink.
    ///
    /// Defaults to `print`.
    var print: (String) -> Void = { Swift.print($0) }

    /// TTY guard.
    ///
    /// Defaults to ``TerminalDetector/isInteractiveInput``.
    var isInteractive: () -> Bool = { TerminalDetector.isInteractiveInput }

    // MARK: - IngestDecisionSource

    func decisions(for proposal: ProposedScope, sharedIDs: [String]) throws -> [KeyDecision] {
        guard isInteractive() else { throw CLIError.notInteractiveTerminal }
        let keys = proposal.detectedKeys
        printHeader(proposal: proposal)
        printContext(proposal: proposal)
        printKeyList(keys: keys)

        // Dominant case: import everything in one keystroke.
        print("")
        let importAll = ask("Import all \(keys.count) as scope-local? [Y/n]")
        if importAll.isEmpty || importAll.lowercased().hasPrefix("y") {
            return keys.map { .importAsLocal(key: $0.key) }
        }

        // Exceptions: which keys get handled differently; the rest are imported.
        let exceptionIndices = parseIndices(
            ask("Which to handle differently? numbers (e.g. 3,7), blank to import the rest:"),
            count: keys.count
        )
        var overrides: [String: KeyDecision] = [:]
        for idx in exceptionIndices {
            overrides[keys[idx].key] = promptChoice(for: keys[idx], sharedIDs: sharedIDs)
        }
        return keys.map { overrides[$0.key] ?? .importAsLocal(key: $0.key) }
    }

    // MARK: - Prompts

    private func ask(_ prompt: String) -> String {
        print(prompt)
        return (lineReader() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func promptChoice(for key: DetectedKey, sharedIDs: [String]) -> KeyDecision {
        let answer = ask("\(key.key)  [i]mport [l]ink [m]ove [x]=leave [s]kip:").lowercased()
        switch answer.first {
        case "l":
            return linkChoice(for: key, sharedIDs: sharedIDs)
        case "m":
            let slug = sanitizeSharedID(ask("New shared entry ID for \(key.key):"))
            return .moveToShared(key: key.key, newSharedID: slug)
        case "x":
            return .leaveAlone(key: key.key)
        case "s":
            return .skip(key: key.key)
        default:
            return .importAsLocal(key: key.key)
        }
    }

    private func linkChoice(for key: DetectedKey, sharedIDs: [String]) -> KeyDecision {
        guard !sharedIDs.isEmpty else {
            print("No shared entries exist yet — importing \(key.key) as scope-local.")
            return .importAsLocal(key: key.key)
        }
        for (idx, id) in sharedIDs.enumerated() {
            print("  \(idx + 1)  \(id)")
        }
        let pick = parseIndices(ask("Link \(key.key) to which? [1]:"), count: sharedIDs.count).first ?? 0
        return .linkToShared(key: key.key, sharedID: sharedIDs[pick])
    }

    // MARK: - Rendering

    private func printHeader(proposal: ProposedScope) {
        print("Scope: \(proposal.suggestedScopeID)  ·  \(proposal.detectedKeys.count) secret(s) detected")
    }

    private func printContext(proposal: ProposedScope) {
        if !proposal.suggestedKeysNeedingValues.isEmpty {
            print("Needs values (from .env.example): \(proposal.suggestedKeysNeedingValues.joined(separator: ", "))")
        }
        for warning in proposal.parseWarnings {
            print("Warning: \(warning.reason) (\(warning.file.lastPathComponent):\(warning.lineNumber))")
        }
    }

    private func printKeyList(keys: [DetectedKey]) {
        print("")
        for (idx, key) in keys.enumerated() {
            var line = "\(String(format: "%2d", idx + 1))  \(key.key)"
            if let matched = key.nameMatchedSharedID {
                line += "  → matches shared '\(matched)'"
            }
            print(line)
        }
    }

    /// Parses a comma/space-separated 1-based index list into deduped 0-based
    /// indices in input order, dropping anything out of range.
    private func parseIndices(_ raw: String, count: Int) -> [Int] {
        var result: [Int] = []
        for token in raw.split(whereSeparator: { $0 == "," || $0 == " " }) {
            guard let value = Int(token), value >= 1, value <= count else { continue }
            let zero = value - 1
            if !result.contains(zero) { result.append(zero) }
        }
        return result
    }
}

// MARK: - Slug sanitizer
//
// Local copy of the scope-ID sanitize rules (same as ho-04.4's dashboard held,
// and ho-04.2's retired prompt before it). If these ever diverge from
// SharibakoCore's scope-ID rules, factor a public helper on SharibakoCore.

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
