import SharibakoCore

/// The non-interactive ``IngestDecisionSource``: every line takes its class
/// default from ``SecretClassifier``, and each line's class is printed.
///
/// Used by `init --yes` and by `init` when stdin is not a terminal (ho-06.10
/// Decision 3). Secrets are imported as scope-local and settings are left
/// alone. A script cannot look at a review screen, so the source prints one
/// line per key to stdout before anything is committed:
///
/// ```
/// PROTECT  OPENAI_API_KEY  (key ends in KEY)
/// LEAVE    PORT  (looks like a number)
/// ```
struct ClassDefaultIngestDecisionSource: IngestDecisionSource {
    /// Output sink.
    ///
    /// Defaults to `print` (stdout).
    var print: (String) -> Void = { Swift.print($0) }

    // MARK: - IngestDecisionSource

    func decisions(for proposal: ProposedScope, sharedIDs: [String]) throws -> [KeyDecision] {
        proposal.classifiedKeys().map { entry in
            print(Self.line(key: entry.key.key, lineClass: entry.lineClass))
            return entry.lineClass.defaultDecision(forKey: entry.key.key)
        }
    }

    /// `PROTECT  KEY  (reason)` or `LEAVE    KEY  (reason)` — the verb padded
    /// to one width so the key column lines up.
    static func line(key: String, lineClass: LineClass) -> String {
        let verb = lineClass.isSecret ? "PROTECT" : "LEAVE  "
        return "\(verb)  \(key)  (\(lineClass.reason.explanation))"
    }
}
