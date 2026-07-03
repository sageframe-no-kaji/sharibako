import SharibakoCore

/// Produces a per-key routing decision for every ``DetectedKey`` in a
/// ``ProposedScope``.
///
/// The two concrete implementations shipped in this module are:
/// - ``PlainIngestPrompt`` — line-based interactive TTY prompt.
/// - ``ScriptedIngestDecisionSource`` — deterministic double used by tests
///   and the deferred non-interactive init path.
protocol IngestDecisionSource {
    /// Returns one ``KeyDecision`` per detected key, in proposal order.
    ///
    /// - Parameters:
    ///   - proposal: The scope proposal from ``Materializer/ingest(directory:)``.
    ///   - sharedIDs: Existing shared-entry IDs available for link-to-shared choices.
    /// - Returns: Decisions in the same order as `proposal.detectedKeys`.
    /// - Throws: Any error raised by the underlying prompt or decision mechanism.
    func decisions(for proposal: ProposedScope, sharedIDs: [String]) throws -> [KeyDecision]
}

// MARK: - KeyDecisionField

/// One labelled row in the per-key ingest prompt.
///
/// Carries enough context to produce the ``KeyDecision`` after the user
/// selects it: the matched shared ID for the "link" row, and a placeholder
/// for the "move" row whose target is collected via a follow-up text prompt.
enum KeyDecisionField {
    /// Encrypt and store as a scope-local secret.
    case importAsLocal
    /// Link to an existing shared entry.
    ///
    /// `matchedID` is non-nil when the Materializer detected a name match —
    /// it is shown in the label and pre-selected in the follow-up shared-ID
    /// picker.
    case linkToShared(matchedID: String?)
    /// Create a new shared entry and link to it.
    case moveToShared
    /// Confirmed non-secret; write nothing.
    case leaveAlone
    /// Deferred; write nothing this run.
    case skip

    /// Human-readable label shown in the choice list.
    var label: String {
        switch self {
        case .importAsLocal:
            "import as scope-local"
        case .linkToShared(let matchedID):
            if let id = matchedID { "link to shared (\(id))" } else { "link to shared" }
        case .moveToShared:
            "move to shared"
        case .leaveAlone:
            "leave alone"
        case .skip:
            "skip"
        }
    }
}
