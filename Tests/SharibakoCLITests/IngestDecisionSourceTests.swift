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

// MARK: - InteractiveIngestPrompt tests

@Suite("InteractiveIngestPrompt")
struct InteractiveIngestPromptTests {
    // MARK: - importAsLocal

    @Test("index 0 yields importAsLocal")
    func importAsLocal() throws {
        let proposal = makeProposal([makeKey("MY_KEY")])
        var prompt = InteractiveIngestPrompt()
        prompt.selectFactory = { _, _, _ in 0 }
        prompt.print = { _ in }

        let result = try prompt.decisions(for: proposal, sharedIDs: [])
        #expect(result == [.importAsLocal(key: "MY_KEY")])
    }

    // MARK: - linkToShared

    @Test("nameMatchedSharedID defaults cursor to link-to-shared and yields linkToShared")
    func matchedSharedIDDefaultsToLink() throws {
        let key = makeKey("OPENAI_KEY", matchedSharedID: "openai-personal")
        let proposal = makeProposal([key])
        var capturedInitialIndex: Int?
        var callCount = 0
        var prompt = InteractiveIngestPrompt()
        prompt.selectFactory = { _, _, initialIndex in
            defer { callCount += 1 }
            if callCount == 0 {
                capturedInitialIndex = initialIndex
                return 1  // choose "link to shared"
            }
            return 0  // choose first shared ID
        }
        prompt.print = { _ in }

        let result = try prompt.decisions(for: proposal, sharedIDs: ["openai-personal"])

        // The link-to-shared row is at index 1 (after "import as scope-local").
        #expect(capturedInitialIndex == 1)
        #expect(result == [.linkToShared(key: "OPENAI_KEY", sharedID: "openai-personal")])
    }

    @Test("link-to-shared second select defaults to matched shared ID position")
    func linkSecondSelectDefaultsToMatch() throws {
        let key = makeKey("KEY", matchedSharedID: "b-entry")
        let proposal = makeProposal([key])
        var secondCallIndex: Int?
        var callCount = 0
        var prompt = InteractiveIngestPrompt()
        prompt.selectFactory = { _, _, initialIndex in
            defer { callCount += 1 }
            if callCount == 0 { return 1 }  // choose "link to shared"
            secondCallIndex = initialIndex
            return initialIndex  // accept the default
        }
        prompt.print = { _ in }

        let sharedIDs = ["a-entry", "b-entry", "c-entry"]
        let result = try prompt.decisions(for: proposal, sharedIDs: sharedIDs)

        // "b-entry" is at index 1 in sharedIDs.
        #expect(secondCallIndex == 1)
        #expect(result == [.linkToShared(key: "KEY", sharedID: "b-entry")])
    }

    // MARK: - empty sharedIDs removes link choice

    @Test("empty sharedIDs omits link-to-shared so import-as-local is at index 0")
    func emptySharedIDsNoLinkChoice() throws {
        let key = makeKey("OPENAI_KEY", matchedSharedID: "openai-personal")
        let proposal = makeProposal([key])
        var capturedChoices: [String] = []
        var capturedInitialIndex: Int?
        var prompt = InteractiveIngestPrompt()
        prompt.selectFactory = { _, choices, initialIndex in
            capturedChoices = choices
            capturedInitialIndex = initialIndex
            return 0  // import as local
        }
        prompt.print = { _ in }

        let result = try prompt.decisions(for: proposal, sharedIDs: [])

        // No "link to shared" in the choices list.
        #expect(!capturedChoices.contains { $0.hasPrefix("link to shared") })
        // Default falls to 0 because there's no link row to default to.
        #expect(capturedInitialIndex == 0)
        #expect(result == [.importAsLocal(key: "OPENAI_KEY")])
    }

    // MARK: - moveToShared

    @Test("move-to-shared collects and sanitizes new slug")
    func moveToSharedSanitizesSlug() throws {
        let proposal = makeProposal([makeKey("MY_KEY")])
        var prompt = InteractiveIngestPrompt()
        // With sharedIDs present, "move to shared" is at index 2.
        prompt.selectFactory = { _, _, _ in 2 }
        prompt.lineReader = { "My New Entry!!" }
        prompt.print = { _ in }

        let result = try prompt.decisions(for: proposal, sharedIDs: ["existing-entry"])
        // "My New Entry!!" → sanitized → "my-new-entry"
        #expect(result == [.moveToShared(key: "MY_KEY", newSharedID: "my-new-entry")])
    }

    @Test("move-to-shared empty slug falls back to 'scope'")
    func moveToSharedEmptySlug() throws {
        let proposal = makeProposal([makeKey("KEY")])
        var prompt = InteractiveIngestPrompt()
        // Without sharedIDs, "move to shared" is at index 1.
        prompt.selectFactory = { _, _, _ in 1 }
        prompt.lineReader = { "!!!###" }  // all non-alphanumeric → sanitizes to empty → "scope"
        prompt.print = { _ in }

        let result = try prompt.decisions(for: proposal, sharedIDs: [])
        #expect(result == [.moveToShared(key: "KEY", newSharedID: "scope")])
    }

    // MARK: - leaveAlone

    @Test("leave-alone yields leaveAlone decision")
    func leaveAlone() throws {
        let proposal = makeProposal([makeKey("NON_SECRET")])
        var prompt = InteractiveIngestPrompt()
        // With sharedIDs present: [importAsLocal(0), linkToShared(1), moveToShared(2), leaveAlone(3), skip(4)]
        prompt.selectFactory = { _, _, _ in 3 }
        prompt.print = { _ in }

        let result = try prompt.decisions(for: proposal, sharedIDs: ["s"])
        #expect(result == [.leaveAlone(key: "NON_SECRET")])
    }

    // MARK: - skip

    @Test("skip yields skip decision")
    func skip() throws {
        let proposal = makeProposal([makeKey("DEFERRED_KEY")])
        var prompt = InteractiveIngestPrompt()
        // With sharedIDs present: skip is at index 4.
        prompt.selectFactory = { _, _, _ in 4 }
        prompt.print = { _ in }

        let result = try prompt.decisions(for: proposal, sharedIDs: ["s"])
        #expect(result == [.skip(key: "DEFERRED_KEY")])
    }

    // MARK: - multi-key walk

    @Test("mixed decisions across multiple keys")
    func mixedDecisionsMultipleKeys() throws {
        let keys = [
            makeKey("IMPORT_ME"),
            makeKey("SKIP_ME"),
            makeKey("LEAVE_ME"),
        ]
        let proposal = makeProposal(keys)
        var callCount = 0
        var prompt = InteractiveIngestPrompt()
        // With empty sharedIDs: [importAsLocal(0), moveToShared(1), leaveAlone(2), skip(3)]
        prompt.selectFactory = { _, _, _ in
            defer { callCount += 1 }
            switch callCount {
            case 0: return 0  // importAsLocal
            case 1: return 3  // skip
            default: return 2  // leaveAlone
            }
        }
        prompt.print = { _ in }

        let result = try prompt.decisions(for: proposal, sharedIDs: [])
        #expect(
            result == [
                .importAsLocal(key: "IMPORT_ME"),
                .skip(key: "SKIP_ME"),
                .leaveAlone(key: "LEAVE_ME"),
            ])
    }

    // MARK: - unmatched key defaulting

    @Test("key without nameMatchedSharedID defaults to index 0 (importAsLocal)")
    func unmatchedKeyDefaultsToImport() throws {
        let key = makeKey("RANDOM_KEY", matchedSharedID: nil)
        let proposal = makeProposal([key])
        var capturedInitialIndex: Int?
        var prompt = InteractiveIngestPrompt()
        prompt.selectFactory = { _, _, initialIndex in
            capturedInitialIndex = initialIndex
            return 0
        }
        prompt.print = { _ in }

        _ = try prompt.decisions(for: proposal, sharedIDs: ["some-entry"])
        #expect(capturedInitialIndex == 0)
    }
}
