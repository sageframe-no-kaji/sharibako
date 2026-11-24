import Foundation
import SharibakoCore

/// The plain line-based implementation of ``IngestDecisionSource``.
///
/// Prints every detected line with its class from ``SecretClassifier``
/// (secret or setting, and why), offers the one-keystroke default — protect
/// the secrets, leave the settings alone — and collects per-key exceptions
/// through simple line prompts whose own default is the line's class. No raw
/// mode, no full-screen rendering — the idiomatic-CLI surface that supersedes
/// ho-04.4's dashboard. The class only sets defaults (ho-06.10 Decision 3).
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
        let classified = proposal.classifiedKeys()
        let secretCount = classified.filter(\.lineClass.isSecret).count
        let settingCount = classified.count - secretCount
        printHeader(scopeID: proposal.suggestedScopeID, secrets: secretCount, settings: settingCount)
        printContext(proposal: proposal)
        printKeyList(classified)
        guard !classified.isEmpty else { return [] }

        // Dominant case: accept every line's class default in one keystroke.
        print("")
        let acceptAll = ask(Self.bulkQuestion(secrets: secretCount, settings: settingCount))
        if acceptAll.isEmpty || acceptAll.lowercased().hasPrefix("y") {
            return classified.map { $0.lineClass.defaultDecision(forKey: $0.key.key) }
        }

        // Exceptions: which keys get handled differently; the rest keep their defaults.
        let exceptionIndices = parseIndices(
            ask("Which to handle differently? numbers (e.g. 3,7), blank to keep the defaults:"),
            count: classified.count
        )
        var overrides: [String: KeyDecision] = [:]
        for idx in exceptionIndices {
            let entry = classified[idx]
            overrides[entry.key.key] = promptChoice(for: entry.key, lineClass: entry.lineClass, sharedIDs: sharedIDs)
        }
        return classified.map { overrides[$0.key.key] ?? $0.lineClass.defaultDecision(forKey: $0.key.key) }
    }

    // MARK: - Wording

    /// The one-keystroke question, zero-aware.
    ///
    /// Both classes present: "Protect 3 secrets and leave 2 settings alone?";
    /// secrets only: "Protect 3 secrets?"; settings only: "Leave all 2
    /// settings alone?" (or "Leave 1 setting alone?").
    static func bulkQuestion(secrets: Int, settings: Int) -> String {
        let question: String
        if settings == 0 {
            question = "Protect \(counted(secrets, "secret"))?"
        } else if secrets == 0 {
            question = settings == 1 ? "Leave 1 setting alone?" : "Leave all \(settings) settings alone?"
        } else {
            question = "Protect \(counted(secrets, "secret")) and leave \(counted(settings, "setting")) alone?"
        }
        return question + " [Y/n]"
    }

    /// `[secret] (reason)` / `[setting] (reason)` — how a line's class reads in the list.
    static func classLabel(_ lineClass: LineClass) -> String {
        let name = lineClass.isSecret ? "secret" : "setting"
        return "[\(name)] (\(lineClass.reason.explanation))"
    }

    /// "1 secret", "3 secrets".
    static func counted(_ count: Int, _ noun: String) -> String {
        count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
    }

    // MARK: - Prompts

    private func ask(_ prompt: String) -> String {
        print(prompt)
        return (lineReader() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Per-key override; Enter (or anything unrecognised) keeps the class default.
    private func promptChoice(for key: DetectedKey, lineClass: LineClass, sharedIDs: [String]) -> KeyDecision {
        let enterMeans = lineClass.isSecret ? "import" : "leave"
        let answer = ask(
            "\(key.key)  \(Self.classLabel(lineClass))  [i]mport [l]ink [m]ove [x]=leave [s]kip, Enter = \(enterMeans):"
        ).lowercased()
        switch answer.first {
        case "i":
            return .importAsLocal(key: key.key)
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
            return lineClass.defaultDecision(forKey: key.key)
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

    private func printHeader(scopeID: String, secrets: Int, settings: Int) {
        print("Scope: \(scopeID)  ·  \(Self.counted(secrets, "secret")), \(Self.counted(settings, "setting"))")
    }

    private func printContext(proposal: ProposedScope) {
        if !proposal.suggestedKeysNeedingValues.isEmpty {
            print("Needs values (from .env.example): \(proposal.suggestedKeysNeedingValues.joined(separator: ", "))")
        }
        for warning in proposal.parseWarnings {
            print("Warning: \(warning.reason) (\(warning.file.lastPathComponent):\(warning.lineNumber))")
        }
    }

    private func printKeyList(_ classified: [(key: DetectedKey, lineClass: LineClass)]) {
        print("")
        for (idx, entry) in classified.enumerated() {
            var line = "\(String(format: "%2d", idx + 1))  \(entry.key.key)  \(Self.classLabel(entry.lineClass))"
            if let matched = entry.key.nameMatchedSharedID {
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
