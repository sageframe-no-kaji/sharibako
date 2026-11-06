import Foundation
import Testing

@testable import SharibakoCLI
@testable import SharibakoCore

// MARK: - Fixtures

private let envURL = URL(fileURLWithPath: "/tmp/.env")

/// Default value is secret-shaped (rule 5 fallback: `+` is no setting shape),
/// so a bare `makeKey("A")` classes as a secret and defaults to import.
private func makeKey(
    _ name: String,
    value: String = "s3cr3t+value",
    matchedSharedID: String? = nil
) -> DetectedKey {
    DetectedKey(key: name, value: value, sourceFile: envURL, nameMatchedSharedID: matchedSharedID)
}

/// Runs the prompt against canned answers and returns its decisions plus
/// every line it printed.
private func runPrompt(
    _ keys: [DetectedKey],
    answers: [String],
    sharedIDs: [String] = []
) throws -> (decisions: [KeyDecision], output: [String]) {
    var queue = answers
    var captured: [String] = []
    var prompt = PlainIngestPrompt()
    prompt.lineReader = { queue.isEmpty ? nil : queue.removeFirst() }
    prompt.print = { captured.append($0) }
    prompt.isInteractive = { true }
    let decisions = try prompt.decisions(for: makeProposal(keys), sharedIDs: sharedIDs)
    return (decisions, captured)
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

// MARK: - Accept the class defaults (dominant case)

@Suite("PlainIngestPrompt — accept defaults")
struct PlainIngestPromptImportAllTests {
    @Test("empty answer imports every secret")
    func emptyImportsAll() throws {
        var out: [String] = []
        let prompt = makePrompt(lines: [""], output: &out)
        let result = try prompt.decisions(for: makeProposal([makeKey("A"), makeKey("B")]), sharedIDs: [])
        #expect(result == [.importAsLocal(key: "A"), .importAsLocal(key: "B")])
    }

    @Test("'y' imports every secret")
    func yesImportsAll() throws {
        var out: [String] = []
        let prompt = makePrompt(lines: ["y"], output: &out)
        let result = try prompt.decisions(for: makeProposal([makeKey("A")]), sharedIDs: [])
        #expect(result == [.importAsLocal(key: "A")])
    }
}

// MARK: - Classes and wording

@Suite("PlainIngestPrompt — classes")
struct PlainIngestPromptClassTests {
    private let mixed = [
        makeKey("OPENAI_API_KEY", value: "sk-proj-abc"),
        makeKey("PORT", value: "3000"),
        makeKey("JWT_SECRET", value: "x"),
        makeKey("NODE_ENV", value: "development"),
    ]

    @Test("accepting protects the secrets and leaves the settings alone")
    func acceptAppliesClassDefaults() throws {
        let run = try runPrompt(mixed, answers: [""])
        #expect(
            run.decisions == [
                .importAsLocal(key: "OPENAI_API_KEY"), .leaveAlone(key: "PORT"),
                .importAsLocal(key: "JWT_SECRET"), .leaveAlone(key: "NODE_ENV"),
            ]
        )
        #expect(run.output.contains("Protect 2 secrets and leave 2 settings alone? [Y/n]"))
    }

    @Test("the key list shows each line's class and reason")
    func keyListShowsClasses() throws {
        let run = try runPrompt(mixed, answers: [""])
        #expect(run.output.contains(" 1  OPENAI_API_KEY  [secret] (key ends in KEY)"))
        #expect(run.output.contains(" 2  PORT  [setting] (looks like a number)"))
        #expect(run.output.contains(" 4  NODE_ENV  [setting] (looks like a plain word)"))
    }

    @Test("the header counts secrets and settings")
    func headerCounts() throws {
        let run = try runPrompt(mixed, answers: [""])
        #expect(run.output.first == "Scope: test-scope  ·  2 secrets, 2 settings")
    }

    @Test("the bulk question is zero-aware and singular-aware")
    func bulkQuestionForms() {
        #expect(
            PlainIngestPrompt.bulkQuestion(secrets: 3, settings: 2)
                == "Protect 3 secrets and leave 2 settings alone? [Y/n]"
        )
        #expect(
            PlainIngestPrompt.bulkQuestion(secrets: 1, settings: 1)
                == "Protect 1 secret and leave 1 setting alone? [Y/n]"
        )
        #expect(PlainIngestPrompt.bulkQuestion(secrets: 3, settings: 0) == "Protect 3 secrets? [Y/n]")
        #expect(PlainIngestPrompt.bulkQuestion(secrets: 1, settings: 0) == "Protect 1 secret? [Y/n]")
        #expect(PlainIngestPrompt.bulkQuestion(secrets: 0, settings: 2) == "Leave all 2 settings alone? [Y/n]")
        #expect(PlainIngestPrompt.bulkQuestion(secrets: 0, settings: 1) == "Leave 1 setting alone? [Y/n]")
    }

    @Test("settings only: accepting leaves every line alone")
    func settingsOnly() throws {
        let run = try runPrompt([makeKey("DEBUG", value: "true"), makeKey("PORT", value: "80")], answers: ["y"])
        #expect(run.decisions == [.leaveAlone(key: "DEBUG"), .leaveAlone(key: "PORT")])
        #expect(run.output.contains("Leave all 2 settings alone? [Y/n]"))
    }

    @Test("declining then blank keeps every class default")
    func declineThenBlankKeepsDefaults() throws {
        let run = try runPrompt(mixed, answers: ["n", ""])
        #expect(
            run.decisions == [
                .importAsLocal(key: "OPENAI_API_KEY"), .leaveAlone(key: "PORT"),
                .importAsLocal(key: "JWT_SECRET"), .leaveAlone(key: "NODE_ENV"),
            ]
        )
    }

    @Test("per-key: Enter keeps the class default, and the prompt names it")
    func perKeyEnterKeepsDefault() throws {
        let run = try runPrompt(mixed, answers: ["n", "1,2", "", ""])
        #expect(run.decisions[0] == .importAsLocal(key: "OPENAI_API_KEY"))
        #expect(run.decisions[1] == .leaveAlone(key: "PORT"))
        #expect(
            run.output.contains {
                $0.hasPrefix("PORT  [setting] (looks like a number)") && $0.hasSuffix("Enter = leave:")
            }
        )
        #expect(run.output.contains { $0.hasPrefix("OPENAI_API_KEY  [secret]") && $0.hasSuffix("Enter = import:") })
    }

    @Test("per-key: a setting can be flipped to import, a secret to leave")
    func perKeyFlips() throws {
        let run = try runPrompt(mixed, answers: ["n", "1,2", "x", "i"])
        #expect(run.decisions[0] == .leaveAlone(key: "OPENAI_API_KEY"))
        #expect(run.decisions[1] == .importAsLocal(key: "PORT"))
    }

    @Test("an empty proposal asks nothing and decides nothing")
    func emptyProposal() throws {
        let run = try runPrompt([], answers: [])
        #expect(run.decisions.isEmpty)
        #expect(!run.output.contains { $0.contains("[Y/n]") })
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

// MARK: - Default seams

@Suite("PlainIngestPrompt — default seams")
struct PlainIngestPromptDefaultSeamTests {
    @Test("default print and TTY-guard closures execute harmlessly")
    func defaultClosuresExecute() {
        let prompt = PlainIngestPrompt()
        // The default output sink is Swift.print — one probe line is harmless.
        prompt.print("sharibako-test: default print probe")
        // The default TTY guard consults TerminalDetector; either answer is valid here.
        _ = prompt.isInteractive()
        // The default lineReader (readLine) is deliberately NOT invoked: it would
        // consume the test runner's stdin.
    }
}
