import Foundation
import Testing

@testable import SharibakoCLI
@testable import SharibakoCore

// MARK: - Fixtures

private let envURL = URL(fileURLWithPath: "/tmp/.env")

private func makeKey(_ name: String, matchedSharedID: String? = nil) -> DetectedKey {
    DetectedKey(key: name, value: "v", sourceFile: envURL, nameMatchedSharedID: matchedSharedID)
}

private func makeProposal(
    _ keys: [DetectedKey],
    scopeID: String = "test-scope",
    needsValues: [String] = [],
    warnings: [ParseWarning] = []
) -> ProposedScope {
    ProposedScope(
        directory: URL(fileURLWithPath: "/tmp/project"),
        suggestedScopeID: scopeID,
        suggestedScopeType: .projectDev,
        detectedKeys: keys,
        suggestedKeysNeedingValues: needsValues,
        parseWarnings: warnings
    )
}

/// Builds a `PlainIngestPrompt` driven by a fixed queue of line responses,
/// capturing everything it prints.
private func makePrompt(
    lines: [String],
    output: inout [String],
    isInteractive: Bool = true
) -> PlainIngestPrompt {
    var queue = lines
    var captured: [String] = []
    var prompt = PlainIngestPrompt()
    prompt.lineReader = { queue.isEmpty ? nil : queue.removeFirst() }
    prompt.print = { captured.append($0) }
    prompt.isInteractive = { isInteractive }
    output = captured
    return prompt
}

// MARK: - Import-all (dominant case)

@Suite("PlainIngestPrompt — import all")
struct PlainIngestPromptImportAllTests {
    @Test("empty answer imports every key")
    func emptyImportsAll() throws {
        var out: [String] = []
        let prompt = makePrompt(lines: [""], output: &out)
        let result = try prompt.decisions(for: makeProposal([makeKey("A"), makeKey("B")]), sharedIDs: [])
        #expect(result == [.importAsLocal(key: "A"), .importAsLocal(key: "B")])
    }

    @Test("'y' imports every key")
    func yesImportsAll() throws {
        var out: [String] = []
        let prompt = makePrompt(lines: ["y"], output: &out)
        let result = try prompt.decisions(for: makeProposal([makeKey("A")]), sharedIDs: [])
        #expect(result == [.importAsLocal(key: "A")])
    }
}

// MARK: - Exceptions

@Suite("PlainIngestPrompt — exceptions")
struct PlainIngestPromptExceptionTests {
    @Test("'n' then blank imports the rest")
    func noThenBlankImportsRest() throws {
        var out: [String] = []
        let prompt = makePrompt(lines: ["n", ""], output: &out)
        let result = try prompt.decisions(for: makeProposal([makeKey("A"), makeKey("B")]), sharedIDs: [])
        #expect(result == [.importAsLocal(key: "A"), .importAsLocal(key: "B")])
    }

    @Test("named exception gets its choice; unnamed keys import")
    func namedExceptionSkips() throws {
        var out: [String] = []
        // Handle key 2 (B) differently → skip; A and C import.
        let prompt = makePrompt(lines: ["n", "2", "s"], output: &out)
        let keys = [makeKey("A"), makeKey("B"), makeKey("C")]
        let result = try prompt.decisions(for: makeProposal(keys), sharedIDs: [])
        #expect(result == [.importAsLocal(key: "A"), .skip(key: "B"), .importAsLocal(key: "C")])
    }

    @Test("each choice letter maps to its decision")
    func choiceLetters() throws {
        var out: [String] = []
        // A→import(i), B→leave(x), C→skip(s); D unnamed → import.
        let prompt = makePrompt(lines: ["n", "1,2,3", "i", "x", "s"], output: &out)
        let keys = [makeKey("A"), makeKey("B"), makeKey("C"), makeKey("D")]
        let result = try prompt.decisions(for: makeProposal(keys), sharedIDs: [])
        #expect(
            result == [
                .importAsLocal(key: "A"), .leaveAlone(key: "B"),
                .skip(key: "C"), .importAsLocal(key: "D"),
            ]
        )
    }

    @Test("unrecognized choice defaults to import")
    func unknownChoiceImports() throws {
        var out: [String] = []
        let prompt = makePrompt(lines: ["n", "1", "?"], output: &out)
        let result = try prompt.decisions(for: makeProposal([makeKey("A")]), sharedIDs: [])
        #expect(result == [.importAsLocal(key: "A")])
    }

    @Test("out-of-range and duplicate exception numbers are ignored")
    func indexParsingRobust() throws {
        var out: [String] = []
        // "0,2,2,99" → only key 2 (index 1) is valid and deduped.
        let prompt = makePrompt(lines: ["n", "0,2,2,99", "s"], output: &out)
        let keys = [makeKey("A"), makeKey("B")]
        let result = try prompt.decisions(for: makeProposal(keys), sharedIDs: [])
        #expect(result == [.importAsLocal(key: "A"), .skip(key: "B")])
    }
}

// MARK: - Move and link

@Suite("PlainIngestPrompt — move and link")
struct PlainIngestPromptMoveLinkTests {
    @Test("move collects and sanitizes a slug")
    func moveSanitizesSlug() throws {
        var out: [String] = []
        let prompt = makePrompt(lines: ["n", "1", "m", "My New Entry!!"], output: &out)
        let result = try prompt.decisions(for: makeProposal([makeKey("A")]), sharedIDs: [])
        #expect(result == [.moveToShared(key: "A", newSharedID: "my-new-entry")])
    }

    @Test("link picks a shared entry by number")
    func linkPicksSharedEntry() throws {
        var out: [String] = []
        let prompt = makePrompt(lines: ["n", "1", "l", "2"], output: &out)
        let result = try prompt.decisions(
            for: makeProposal([makeKey("A")]),
            sharedIDs: ["one", "two", "three"]
        )
        #expect(result == [.linkToShared(key: "A", sharedID: "two")])
    }

    @Test("link with no shared entries falls back to import")
    func linkFallsBackWhenNoShared() throws {
        var out: [String] = []
        let prompt = makePrompt(lines: ["n", "1", "l"], output: &out)
        let result = try prompt.decisions(for: makeProposal([makeKey("A")]), sharedIDs: [])
        #expect(result == [.importAsLocal(key: "A")])
    }
}

// MARK: - Rendering and refusal

@Suite("PlainIngestPrompt — rendering and refusal")
struct PlainIngestPromptRenderingTests {
    @Test("non-TTY throws notInteractiveTerminal without reading")
    func nonTTYRefuses() throws {
        var out: [String] = []
        let prompt = makePrompt(lines: [], output: &out, isInteractive: false)
        #expect(throws: CLIError.notInteractiveTerminal) {
            try prompt.decisions(for: makeProposal([makeKey("A")]), sharedIDs: [])
        }
    }

    @Test("name-matched key is noted in the printed list")
    func nameMatchNoted() throws {
        var captured: [String] = []
        var queue = [""]
        var prompt = PlainIngestPrompt()
        prompt.lineReader = { queue.isEmpty ? nil : queue.removeFirst() }
        prompt.print = { captured.append($0) }
        prompt.isInteractive = { true }
        _ = try prompt.decisions(
            for: makeProposal([makeKey("OPENAI_API_KEY", matchedSharedID: "openai-personal")]),
            sharedIDs: ["openai-personal"]
        )
        #expect(captured.contains { $0.contains("OPENAI_API_KEY") && $0.contains("openai-personal") })
    }

    @Test("needs-values and parse warnings print as context")
    func contextLinesPrint() throws {
        var captured: [String] = []
        var queue = [""]
        var prompt = PlainIngestPrompt()
        prompt.lineReader = { queue.isEmpty ? nil : queue.removeFirst() }
        prompt.print = { captured.append($0) }
        prompt.isInteractive = { true }
        let warning = ParseWarning(file: envURL, lineNumber: 4, text: "BAD", reason: "unquoted value")
        _ = try prompt.decisions(
            for: makeProposal([makeKey("A")], needsValues: ["MISSING"], warnings: [warning]),
            sharedIDs: []
        )
        #expect(captured.contains { $0.contains("MISSING") })
        #expect(captured.contains { $0.contains("unquoted value") })
    }
}
