import Foundation
import Testing

@testable import SharibakoCLI
@testable import SharibakoCore

// MARK: - Shared fixtures

private let envURL = URL(fileURLWithPath: "/tmp/.env")
private let exampleURL = URL(fileURLWithPath: "/tmp/.env.example")

private func makeKey(_ name: String, matchedSharedID: String? = nil) -> DetectedKey {
    DetectedKey(key: name, value: "v", sourceFile: envURL, nameMatchedSharedID: matchedSharedID)
}

private func makeProposal(
    keys: [DetectedKey],
    scopeID: String = "test-scope",
    needingValues: [String] = [],
    warnings: [ParseWarning] = []
) -> ProposedScope {
    ProposedScope(
        directory: URL(fileURLWithPath: "/tmp/project"),
        suggestedScopeID: scopeID,
        suggestedScopeType: .projectDev,
        detectedKeys: keys,
        suggestedKeysNeedingValues: needingValues,
        parseWarnings: warnings
    )
}

private func makeWarning(_ reason: String, line: Int = 1) -> ParseWarning {
    ParseWarning(file: exampleURL, lineNumber: line, text: "X=", reason: reason)
}

// MARK: - Tests

@Suite("DashboardIngestPrompt — decision mapping")
struct DashboardIngestPromptDecisionMappingTests {
    @Test("importAsLocal choice maps to importAsLocal decision")
    func importAsLocalMapping() throws {
        let proposal = makeProposal(keys: [makeKey("API_KEY")])
        var prompt = DashboardIngestPrompt()
        prompt.dashboardRunner = { _, _, _ in [.importAsLocal] }
        let result = try prompt.decisions(for: proposal, sharedIDs: [])
        #expect(result == [.importAsLocal(key: "API_KEY")])
    }

    @Test("linkToShared choice maps to linkToShared decision with correct sharedID")
    func linkToSharedMapping() throws {
        let proposal = makeProposal(keys: [makeKey("OPENAI_KEY")])
        var prompt = DashboardIngestPrompt()
        prompt.dashboardRunner = { _, _, _ in [.linkToShared(sharedID: "openai-personal")] }
        let result = try prompt.decisions(for: proposal, sharedIDs: ["openai-personal"])
        #expect(result == [.linkToShared(key: "OPENAI_KEY", sharedID: "openai-personal")])
    }

    @Test("moveToShared choice maps to moveToShared decision with correct newSharedID")
    func moveToSharedMapping() throws {
        let proposal = makeProposal(keys: [makeKey("DB_URL")])
        var prompt = DashboardIngestPrompt()
        prompt.dashboardRunner = { _, _, _ in [.moveToShared(newSharedID: "my-db")] }
        let result = try prompt.decisions(for: proposal, sharedIDs: [])
        #expect(result == [.moveToShared(key: "DB_URL", newSharedID: "my-db")])
    }

    @Test("leaveAlone choice maps to leaveAlone decision")
    func leaveAloneMapping() throws {
        let proposal = makeProposal(keys: [makeKey("PORT")])
        var prompt = DashboardIngestPrompt()
        prompt.dashboardRunner = { _, _, _ in [.leaveAlone] }
        let result = try prompt.decisions(for: proposal, sharedIDs: [])
        #expect(result == [.leaveAlone(key: "PORT")])
    }

    @Test("skip choice maps to skip decision")
    func skipMapping() throws {
        let proposal = makeProposal(keys: [makeKey("DEFERRED")])
        var prompt = DashboardIngestPrompt()
        prompt.dashboardRunner = { _, _, _ in [.skip] }
        let result = try prompt.decisions(for: proposal, sharedIDs: [])
        #expect(result == [.skip(key: "DEFERRED")])
    }

    @Test("all five choices mapped correctly in proposal order")
    func allFiveChoicesMappedInOrder() throws {
        let keys = [
            makeKey("A"),
            makeKey("B", matchedSharedID: "shared-b"),
            makeKey("C"),
            makeKey("D"),
            makeKey("E"),
        ]
        let proposal = makeProposal(keys: keys)
        var prompt = DashboardIngestPrompt()
        prompt.dashboardRunner = { _, _, _ in
            [
                .importAsLocal,
                .linkToShared(sharedID: "shared-b"),
                .moveToShared(newSharedID: "new-c"),
                .leaveAlone,
                .skip,
            ]
        }
        let result = try prompt.decisions(for: proposal, sharedIDs: ["shared-b"])
        #expect(
            result == [
                .importAsLocal(key: "A"),
                .linkToShared(key: "B", sharedID: "shared-b"),
                .moveToShared(key: "C", newSharedID: "new-c"),
                .leaveAlone(key: "D"),
                .skip(key: "E"),
            ])
    }
}

@Suite("DashboardIngestPrompt — banner construction")
struct DashboardIngestPromptBannerTests {
    @Test("banner includes suggestedKeysNeedingValues when non-empty")
    func bannerIncludesNeedingValues() throws {
        let proposal = makeProposal(keys: [makeKey("A")], needingValues: ["FOO", "BAR"])
        var capturedBanner: [String] = []
        var prompt = DashboardIngestPrompt()
        prompt.dashboardRunner = { _, _, banner in
            capturedBanner = banner
            return [.importAsLocal]
        }
        _ = try prompt.decisions(for: proposal, sharedIDs: [])
        #expect(capturedBanner.contains { $0.contains("FOO") && $0.contains("BAR") })
    }

    @Test("banner includes parse warnings when present")
    func bannerIncludesParseWarnings() throws {
        let warning = makeWarning("unexpected token", line: 5)
        let proposal = makeProposal(keys: [makeKey("A")], warnings: [warning])
        var capturedBanner: [String] = []
        var prompt = DashboardIngestPrompt()
        prompt.dashboardRunner = { _, _, banner in
            capturedBanner = banner
            return [.importAsLocal]
        }
        _ = try prompt.decisions(for: proposal, sharedIDs: [])
        #expect(capturedBanner.contains { $0.contains("unexpected token") })
    }

    @Test("banner is empty when no needingValues and no warnings")
    func bannerIsEmptyWhenClean() throws {
        let proposal = makeProposal(keys: [makeKey("A")])
        var capturedBanner: [String] = []
        var prompt = DashboardIngestPrompt()
        prompt.dashboardRunner = { _, _, banner in
            capturedBanner = banner
            return [.importAsLocal]
        }
        _ = try prompt.decisions(for: proposal, sharedIDs: [])
        #expect(capturedBanner.isEmpty)
    }
}

@Suite("DashboardIngestPrompt — row construction")
struct DashboardIngestPromptRowTests {
    @Test("rows are built from detectedKeys in proposal order")
    func rowsBuiltInOrder() throws {
        let keys = [makeKey("Z"), makeKey("A"), makeKey("M")]
        let proposal = makeProposal(keys: keys)
        var capturedRows: [IngestDashboard.Row] = []
        var prompt = DashboardIngestPrompt()
        prompt.dashboardRunner = { rows, _, _ in
            capturedRows = rows
            return Array(repeating: .importAsLocal, count: rows.count)
        }
        _ = try prompt.decisions(for: proposal, sharedIDs: [])
        #expect(capturedRows.map(\.key) == ["Z", "A", "M"])
    }

    @Test("nameMatchedSharedID is passed to the row")
    func matchedSharedIDPassedToRow() throws {
        let key = makeKey("OPENAI_KEY", matchedSharedID: "openai-personal")
        let proposal = makeProposal(keys: [key])
        var capturedRows: [IngestDashboard.Row] = []
        var prompt = DashboardIngestPrompt()
        prompt.dashboardRunner = { rows, _, _ in
            capturedRows = rows
            return [.importAsLocal]
        }
        _ = try prompt.decisions(for: proposal, sharedIDs: ["openai-personal"])
        #expect(capturedRows.first?.matchedSharedID == "openai-personal")
    }

    @Test("sharedIDs are passed through to the runner")
    func sharedIDsPassedThrough() throws {
        let proposal = makeProposal(keys: [makeKey("KEY")])
        var capturedSharedIDs: [String] = []
        var prompt = DashboardIngestPrompt()
        prompt.dashboardRunner = { _, sharedIDs, _ in
            capturedSharedIDs = sharedIDs
            return [.importAsLocal]
        }
        _ = try prompt.decisions(for: proposal, sharedIDs: ["entry-a", "entry-b"])
        #expect(capturedSharedIDs == ["entry-a", "entry-b"])
    }
}

@Suite("DashboardIngestPrompt — error propagation")
struct DashboardIngestPromptErrorTests {
    @Test("aborted from runner propagates as CLIError.aborted")
    func abortedPropagates() throws {
        let proposal = makeProposal(keys: [makeKey("KEY")])
        var prompt = DashboardIngestPrompt()
        prompt.dashboardRunner = { _, _, _ in throw CLIError.aborted }
        #expect(throws: CLIError.aborted) {
            try prompt.decisions(for: proposal, sharedIDs: [])
        }
    }

    @Test("notInteractiveTerminal from runner propagates unchanged")
    func notInteractiveTerminalPropagates() throws {
        let proposal = makeProposal(keys: [makeKey("KEY")])
        var prompt = DashboardIngestPrompt()
        prompt.dashboardRunner = { _, _, _ in throw CLIError.notInteractiveTerminal }
        #expect(throws: CLIError.notInteractiveTerminal) {
            try prompt.decisions(for: proposal, sharedIDs: [])
        }
    }
}
