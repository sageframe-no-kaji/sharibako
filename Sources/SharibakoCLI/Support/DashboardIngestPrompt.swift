import SharibakoCore

/// An `IngestDecisionSource` that routes all detected keys through `IngestDashboard`.
///
/// Builds the dashboard rows from `proposal.detectedKeys`, passes `sharedIDs`,
/// constructs a read-only banner from `suggestedKeysNeedingValues` and
/// `parseWarnings`, runs the dashboard, and maps each `ResolvedChoice` back to
/// a `KeyDecision` in proposal order.
///
/// ## Testability
///
/// Inject `dashboardRunner` to supply canned `[ResolvedChoice]` values without
/// a real terminal.  Propagates `CLIError.aborted` and
/// `CLIError.notInteractiveTerminal` unchanged.
struct DashboardIngestPrompt: IngestDecisionSource {
    /// Factory that runs the dashboard and returns one `ResolvedChoice` per row.
    ///
    /// Parameters: `(rows, sharedIDs, banner)`.
    /// Default builds a real `IngestDashboard` and calls `run()`.
    /// Inject in tests to return predetermined choices without a TTY.
    var dashboardRunner:
        (_ rows: [IngestDashboard.Row], _ sharedIDs: [String], _ banner: [String]) throws
            -> [ResolvedChoice] = { rows, sharedIDs, banner in
                try IngestDashboard(rows: rows, sharedIDs: sharedIDs, banner: banner).run()
            }

    // MARK: - IngestDecisionSource

    /// Runs the dashboard and maps the result to `[KeyDecision]` in proposal order.
    func decisions(for proposal: ProposedScope, sharedIDs: [String]) throws -> [KeyDecision] {
        let rows = proposal.detectedKeys.map { detected in
            IngestDashboard.Row(key: detected.key, matchedSharedID: detected.nameMatchedSharedID)
        }
        let banner = buildBanner(proposal: proposal)
        let resolved = try dashboardRunner(rows, sharedIDs, banner)
        return zip(proposal.detectedKeys, resolved).map { detected, choice in
            keyDecision(for: detected.key, choice: choice)
        }
    }

    // MARK: - Private helpers

    private func buildBanner(proposal: ProposedScope) -> [String] {
        var lines: [String] = []
        if !proposal.suggestedKeysNeedingValues.isEmpty {
            lines.append(
                "Keys needing values (from .env.example): \(proposal.suggestedKeysNeedingValues.joined(separator: ", "))"
            )
        }
        for warning in proposal.parseWarnings {
            lines.append("Parse warning (line \(warning.lineNumber)): \(warning.reason)")
        }
        return lines
    }

    private func keyDecision(for key: String, choice: ResolvedChoice) -> KeyDecision {
        switch choice {
        case .importAsLocal:
            return .importAsLocal(key: key)
        case .linkToShared(let sharedID):
            return .linkToShared(key: key, sharedID: sharedID)
        case .moveToShared(let newSharedID):
            return .moveToShared(key: key, newSharedID: newSharedID)
        case .leaveAlone:
            return .leaveAlone(key: key)
        case .skip:
            return .skip(key: key)
        }
    }
}
