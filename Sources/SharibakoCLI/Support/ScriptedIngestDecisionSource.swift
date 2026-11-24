import SharibakoCore

/// A deterministic ``IngestDecisionSource`` backed by a fixed decision map.
///
/// Used by tests to cover every ``KeyDecision`` branch without a real
/// terminal. Lives in `Sources/` — not `Tests/` — alongside the production
/// sources it stands in for. The production non-interactive `init` path is
/// ``ClassDefaultIngestDecisionSource`` (ho-06.10), which defaults each line
/// from its class rather than from a fixed map.
///
/// ## Usage
///
/// ```swift
/// // Explicit per-key decisions:
/// let source = ScriptedIngestDecisionSource(
///     decisions: ["API_KEY": .importAsLocal(key: "API_KEY")],
///     fallback: { .skip(key: $0) }
/// )
///
/// // Uniform "import everything" convenience:
/// let source = ScriptedIngestDecisionSource.allImportLocal()
/// ```
struct ScriptedIngestDecisionSource: IngestDecisionSource {
    /// Per-key decisions keyed by key name.
    let decisionMap: [String: KeyDecision]

    /// Called for any key not present in `decisionMap`.
    ///
    /// When `nil`, keys missing from `decisionMap` throw
    /// ``ScriptedIngestError/noDecisionForKey(_:)``.
    let fallback: ((String) -> KeyDecision)?

    /// Creates a source with explicit per-key decisions and an optional
    /// fallback for unspecified keys.
    init(decisions: [String: KeyDecision], fallback: ((String) -> KeyDecision)? = nil) {
        self.decisionMap = decisions
        self.fallback = fallback
    }

    // MARK: - IngestDecisionSource

    func decisions(for proposal: ProposedScope, sharedIDs: [String]) throws -> [KeyDecision] {
        try proposal.detectedKeys.map { detected in
            if let decision = decisionMap[detected.key] {
                return decision
            }
            if let makeFallback = fallback {
                return makeFallback(detected.key)
            }
            throw ScriptedIngestError.noDecisionForKey(detected.key)
        }
    }

    // MARK: - Convenience constructors

    /// Returns a source that imports every detected key as scope-local.
    ///
    /// Test convenience: drives `init` past the decision step with every key
    /// written, regardless of class.
    static func allImportLocal() -> Self {
        Self(decisions: [:]) { .importAsLocal(key: $0) }
    }

    /// Returns a source that leaves every detected key alone.
    static func allLeaveAlone() -> Self {
        Self(decisions: [:]) { .leaveAlone(key: $0) }
    }

    /// Returns a source that skips every detected key.
    static func allSkip() -> Self {
        Self(decisions: [:]) { .skip(key: $0) }
    }

    // MARK: - Error

    /// Errors thrown when the scripted source cannot produce a decision.
    enum ScriptedIngestError: Error, Equatable {
        /// `decisionMap` has no entry for `key` and no `fallback` was set.
        case noDecisionForKey(String)
    }
}
