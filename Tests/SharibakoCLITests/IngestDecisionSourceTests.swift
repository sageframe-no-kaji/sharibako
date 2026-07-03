import Foundation
import Testing

@testable import SharibakoCLI
@testable import SharibakoCore

// MARK: - Shared fixtures

private let envURL = URL(fileURLWithPath: "/tmp/.env")

private func makeKey(_ name: String, matchedSharedID: String? = nil) -> DetectedKey {
    DetectedKey(key: name, value: "test-value", sourceFile: envURL, nameMatchedSharedID: matchedSharedID)
}

private func makeProposal(_ keys: [DetectedKey], scopeID: String = "test-scope") -> ProposedScope {
    ProposedScope(
        directory: URL(fileURLWithPath: "/tmp/project"),
        suggestedScopeID: scopeID,
        suggestedScopeType: .projectDev,
        detectedKeys: keys,
        suggestedKeysNeedingValues: [],
        parseWarnings: []
    )
}

// MARK: - ScriptedIngestDecisionSource tests

@Suite("ScriptedIngestDecisionSource")
struct ScriptedIngestDecisionSourceTests {
    @Test("explicit map returns per-key decisions in proposal order")
    func explicitMap() throws {
        let source = ScriptedIngestDecisionSource(decisions: [
            "API_KEY": .importAsLocal(key: "API_KEY"),
            "DB_URL": .skip(key: "DB_URL"),
        ])
        let proposal = makeProposal([makeKey("API_KEY"), makeKey("DB_URL")])
        let result = try source.decisions(for: proposal, sharedIDs: [])
        #expect(result == [.importAsLocal(key: "API_KEY"), .skip(key: "DB_URL")])
    }

    @Test("fallback is used for keys not in the map")
    func fallbackUsed() throws {
        let source = ScriptedIngestDecisionSource(
            decisions: ["API_KEY": .importAsLocal(key: "API_KEY")]
        ) { .leaveAlone(key: $0) }
        let proposal = makeProposal([makeKey("API_KEY"), makeKey("OTHER")])
        let result = try source.decisions(for: proposal, sharedIDs: [])
        #expect(result == [.importAsLocal(key: "API_KEY"), .leaveAlone(key: "OTHER")])
    }

    @Test("missing key without fallback throws noDecisionForKey")
    func missingKeyThrows() throws {
        let source = ScriptedIngestDecisionSource(decisions: [:])
        let proposal = makeProposal([makeKey("UNKNOWN")])
        #expect(
            throws: ScriptedIngestDecisionSource.ScriptedIngestError.noDecisionForKey("UNKNOWN")
        ) {
            try source.decisions(for: proposal, sharedIDs: [])
        }
    }

    @Test("allImportLocal maps every detected key to importAsLocal")
    func allImportLocal() throws {
        let source = ScriptedIngestDecisionSource.allImportLocal()
        let proposal = makeProposal([makeKey("A"), makeKey("B"), makeKey("C")])
        let result = try source.decisions(for: proposal, sharedIDs: [])
        #expect(
            result == [
                .importAsLocal(key: "A"),
                .importAsLocal(key: "B"),
                .importAsLocal(key: "C"),
            ])
    }

    @Test("allLeaveAlone maps every key to leaveAlone")
    func allLeaveAlone() throws {
        let source = ScriptedIngestDecisionSource.allLeaveAlone()
        let proposal = makeProposal([makeKey("X"), makeKey("Y")])
        let result = try source.decisions(for: proposal, sharedIDs: [])
        #expect(result == [.leaveAlone(key: "X"), .leaveAlone(key: "Y")])
    }

    @Test("allSkip maps every key to skip")
    func allSkip() throws {
        let source = ScriptedIngestDecisionSource.allSkip()
        let proposal = makeProposal([makeKey("Z")])
        let result = try source.decisions(for: proposal, sharedIDs: [])
        #expect(result == [.skip(key: "Z")])
    }

    @Test("empty proposal returns empty decisions")
    func emptyProposal() throws {
        let source = ScriptedIngestDecisionSource.allImportLocal()
        let result = try source.decisions(for: makeProposal([]), sharedIDs: [])
        #expect(result.isEmpty)
    }
}

// MARK: - KeyDecisionField tests

@Suite("KeyDecisionField")
struct KeyDecisionFieldTests {
    @Test("importAsLocal labels as scope-local import")
    func importAsLocalLabel() {
        #expect(KeyDecisionField.importAsLocal.label == "import as scope-local")
    }

    @Test("linkToShared without a match omits the shared ID")
    func linkToSharedNoMatchLabel() {
        #expect(KeyDecisionField.linkToShared(matchedID: nil).label == "link to shared")
    }

    @Test("linkToShared with a match shows the matched shared ID")
    func linkToSharedMatchedLabel() {
        let field = KeyDecisionField.linkToShared(matchedID: "OPENAI_API_KEY")
        #expect(field.label == "link to shared (OPENAI_API_KEY)")
    }

    @Test("moveToShared labels as move to shared")
    func moveToSharedLabel() {
        #expect(KeyDecisionField.moveToShared.label == "move to shared")
    }

    @Test("leaveAlone labels as leave alone")
    func leaveAloneLabel() {
        #expect(KeyDecisionField.leaveAlone.label == "leave alone")
    }

    @Test("skip labels as skip")
    func skipLabel() {
        #expect(KeyDecisionField.skip.label == "skip")
    }
}
