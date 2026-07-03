import Foundation
import Testing

@testable import SharibakoCLI

// MARK: - Helpers

private func makeDashboard(
    rows: [IngestDashboard.Row],
    sharedIDs: [String] = [],
    banner: [String] = [],
    bytes: [UInt8]
) -> (IngestDashboard, captured: () -> [String]) {
    var queue = bytes
    var frames: [String] = []
    var dashboard = IngestDashboard(rows: rows, sharedIDs: sharedIDs, banner: banner)
    dashboard.readByte = { queue.isEmpty ? nil : queue.removeFirst() }
    dashboard.write = { frames.append($0) }
    dashboard.isInteractive = { true }
    return (dashboard, { frames })
}

private func row(_ key: String, matchedSharedID: String? = nil) -> IngestDashboard.Row {
    IngestDashboard.Row(key: key, matchedSharedID: matchedSharedID)
}

// Byte sequences used in tests.
private let up: [UInt8] = [0x1B, 0x5B, 0x41]
private let down: [UInt8] = [0x1B, 0x5B, 0x42]
private let right: [UInt8] = [0x1B, 0x5B, 0x43]
private let left: [UInt8] = [0x1B, 0x5B, 0x44]
private let enter: [UInt8] = [0x0A]
// A lone ESC in sub-modes: the handler peeks one byte to distinguish Esc from
// an arrow sequence. Using 0x00 as the peek byte (not 0x5B) triggers the
// "lone Esc" branch while the 0x00 is consumed harmlessly.
private let escCancel: [UInt8] = [0x1B, 0x00]
// A lone ESC in main mode: the handler throws aborted when the next byte is
// nil (queue exhausted) or not 0x5B — a single 0x1B works.
private let escMain: [UInt8] = [0x1B]
private let space: [UInt8] = [0x20]
private let aKey: [UInt8] = [0x61]

// MARK: - Navigation tests

@Suite("IngestDashboard — navigation")
struct IngestDashboardNavigationTests {
    @Test("enter on first row commits with default import choices")
    func enterAtTopCommitsDefaults() throws {
        let (dashboard, _) = makeDashboard(rows: [row("A"), row("B")], bytes: enter)
        let result = try dashboard.run()
        #expect(result == [.importAsLocal, .importAsLocal])
    }

    @Test("down then enter retains choices")
    func downThenEnterRetainsChoices() throws {
        let (dashboard, _) = makeDashboard(
            rows: [row("A"), row("B"), row("C")],
            bytes: down + enter
        )
        let result = try dashboard.run()
        #expect(result == [.importAsLocal, .importAsLocal, .importAsLocal])
    }

    @Test("down-down-up lands on second row")
    func downDownUpLandsOnSecondRow() throws {
        // Verifies clamping: navigation doesn't change choices.
        let (dashboard, _) = makeDashboard(
            rows: [row("A"), row("B"), row("C")],
            bytes: down + down + up + enter
        )
        let result = try dashboard.run()
        #expect(result == [.importAsLocal, .importAsLocal, .importAsLocal])
    }

    @Test("up at top clamps")
    func upAtTopClamped() throws {
        let (dashboard, _) = makeDashboard(
            rows: [row("A"), row("B")],
            bytes: up + enter
        )
        let result = try dashboard.run()
        #expect(result == [.importAsLocal, .importAsLocal])
    }

    @Test("down at bottom clamps")
    func downAtBottomClamped() throws {
        let (dashboard, _) = makeDashboard(
            rows: [row("A"), row("B")],
            bytes: down + down + enter
        )
        let result = try dashboard.run()
        #expect(result == [.importAsLocal, .importAsLocal])
    }
}

// MARK: - Initial state tests

@Suite("IngestDashboard — initial state")
struct IngestDashboardInitialStateTests {
    @Test("row with matchedSharedID starts on link with that ID")
    func matchedSharedIDStartsOnLink() throws {
        let (dashboard, _) = makeDashboard(
            rows: [row("OPENAI_KEY", matchedSharedID: "openai-personal")],
            sharedIDs: ["openai-personal", "other"],
            bytes: enter
        )
        let result = try dashboard.run()
        #expect(result == [.linkToShared(sharedID: "openai-personal")])
    }

    @Test("row without matchedSharedID starts on import")
    func noMatchStartsOnImport() throws {
        let (dashboard, _) = makeDashboard(
            rows: [row("RANDOM_KEY")],
            sharedIDs: ["some-entry"],
            bytes: enter
        )
        let result = try dashboard.run()
        #expect(result == [.importAsLocal])
    }

    @Test("matchedSharedID with empty sharedIDs falls back to import")
    func matchedSharedIDWithEmptySharedIDsStartsOnImport() throws {
        let (dashboard, _) = makeDashboard(
            rows: [row("OPENAI_KEY", matchedSharedID: "openai-personal")],
            sharedIDs: [],
            bytes: enter
        )
        let result = try dashboard.run()
        #expect(result == [.importAsLocal])
    }

    @Test("initial render contains the key name")
    func initialRenderContainsKeyName() throws {
        let (dashboard, captured) = makeDashboard(rows: [row("MY_SECRET")], bytes: enter)
        _ = try dashboard.run()
        #expect(captured().joined().contains("MY_SECRET"))
    }
}

// MARK: - Choice cycling tests

@Suite("IngestDashboard — choice cycling")
struct IngestDashboardCycleTests {
    @Test("right opens move slug field; confirming empty slug yields 'scope'")
    func rightToMoveEmptySlugYieldsScope() throws {
        // No sharedIDs: cycle is import → move → leave → skip → (wrap) → import
        let (dashboard, _) = makeDashboard(
            rows: [row("KEY")],
            sharedIDs: [],
            bytes: right + enter + enter  // right→slug, Enter confirm empty→"scope", Enter commit
        )
        let result = try dashboard.run()
        #expect(result == [.moveToShared(newSharedID: "scope")])
    }

    @Test("left from import wraps to skip")
    func leftFromImportWrapsToSkip() throws {
        let (dashboard, _) = makeDashboard(
            rows: [row("KEY")],
            sharedIDs: [],
            bytes: left + enter
        )
        let result = try dashboard.run()
        #expect(result == [.skip])
    }

    @Test("right then right cycles move → leave")
    func rightRightCyclesMoveToLeave() throws {
        // right → slug (enter to confirm empty→"scope"), right → leave, Enter commit
        let (dashboard, _) = makeDashboard(
            rows: [row("KEY")],
            sharedIDs: [],
            bytes: right + enter + right + enter
        )
        let result = try dashboard.run()
        #expect(result == [.leaveAlone])
    }

    @Test("right with sharedIDs opens link picker; confirming first entry records linkToShared")
    func rightOpensLinkPickerWithSharedIDs() throws {
        let (dashboard, _) = makeDashboard(
            rows: [row("KEY")],
            sharedIDs: ["entry-a", "entry-b"],
            bytes: right + enter + enter  // right→link picker, Enter confirm entry-a, Enter commit
        )
        let result = try dashboard.run()
        #expect(result == [.linkToShared(sharedID: "entry-a")])
    }

    @Test("cycle different rows independently then commit")
    func cycleRowsIndependently() throws {
        // Row A: right(→slug) + Enter(confirm empty→"scope") + right(→leave) → leaveAlone
        // Row B: stays import
        let (dashboard, _) = makeDashboard(
            rows: [row("A"), row("B")],
            sharedIDs: [],
            bytes: right + enter + right + down + enter
        )
        let result = try dashboard.run()
        #expect(result == [.leaveAlone, .importAsLocal])
    }
}

// MARK: - Mark and ALL tests

@Suite("IngestDashboard — mark and ALL bulk")
struct IngestDashboardMarkAllTests {
    @Test("space marks active row; ALL leave applies only to marked rows")
    func spaceMarkThenAllLeaveOnlyAffectsMarked() throws {
        // Mark row A (index 0), open ALL picker, select leave (index 1 via down), apply
        let (dashboard, _) = makeDashboard(
            rows: [row("A"), row("B")],
            sharedIDs: [],
            bytes: space + aKey + down + enter + enter
        )
        let result = try dashboard.run()
        #expect(result == [.leaveAlone, .importAsLocal])
    }

    @Test("ALL with no marks applies import to every row")
    func allWithNoMarksAppliesImportEverywhere() throws {
        // ALL picker: index 0 = import, Enter to apply (no marks → all rows), Enter to commit
        let (dashboard, _) = makeDashboard(
            rows: [row("A"), row("B"), row("C")],
            sharedIDs: [],
            bytes: aKey + enter + enter
        )
        let result = try dashboard.run()
        #expect(result == [.importAsLocal, .importAsLocal, .importAsLocal])
    }

    @Test("ALL skip applies to every row when none marked")
    func allSkipNoMarksEveryRow() throws {
        // ALL picker: down×2 → index 2 = skip, Enter apply, Enter commit
        let (dashboard, _) = makeDashboard(
            rows: [row("A"), row("B")],
            sharedIDs: [],
            bytes: aKey + down + down + enter + enter
        )
        let result = try dashboard.run()
        #expect(result == [.skip, .skip])
    }

    @Test("ALL leave applies to two marked rows, leaves unmarked row as import")
    func allLeaveOnTwoMarkedRows() throws {
        // Mark A (space), navigate to C (down+down+space), ALL leave (a+down+enter), commit
        let (dashboard, _) = makeDashboard(
            rows: [row("A"), row("B"), row("C")],
            sharedIDs: [],
            bytes: space + down + down + space + aKey + down + enter + enter
        )
        let result = try dashboard.run()
        #expect(result == [.leaveAlone, .importAsLocal, .leaveAlone])
    }

    @Test("ALL Esc cancels picker without applying any change")
    func allEscCancelsWithoutApplying() throws {
        // Cycle A to skip first, then open ALL, Esc cancel, commit → A stays skip
        let (dashboard, _) = makeDashboard(
            rows: [row("A"), row("B")],
            sharedIDs: [],
            // left from import → skip; a (ALL picker); escCancel; Enter commit
            bytes: left + aKey + escCancel + enter
        )
        let result = try dashboard.run()
        #expect(result == [.skip, .importAsLocal])
    }

    @Test("ALL overwrites existing non-default choices")
    func allOverwritesExistingChoices() throws {
        // Cycle A to skip (left from import), then ALL import on all → both import
        let (dashboard, _) = makeDashboard(
            rows: [row("A"), row("B")],
            sharedIDs: [],
            bytes: left + aKey + enter + enter  // left→skip, ALL(import), Enter apply, Enter commit
        )
        let result = try dashboard.run()
        #expect(result == [.importAsLocal, .importAsLocal])
    }
}

// MARK: - Link sub-pick tests

@Suite("IngestDashboard — link sub-pick")
struct IngestDashboardLinkPickTests {
    @Test("cycling to link opens shared list; navigating down and confirming records second entry")
    func linkPickNavigationSelectsEntry() throws {
        let (dashboard, _) = makeDashboard(
            rows: [row("KEY")],
            sharedIDs: ["alpha", "beta", "gamma"],
            bytes: right + down + enter + enter  // right→link picker, down (beta), Enter confirm, Enter commit
        )
        let result = try dashboard.run()
        #expect(result == [.linkToShared(sharedID: "beta")])
    }

    @Test("cycling back to link after move opens picker defaulting to matchedSharedID")
    func linkPickerDefaultsToMatchedID() throws {
        let (dashboard, _) = makeDashboard(
            rows: [row("KEY", matchedSharedID: "beta")],
            sharedIDs: ["alpha", "beta", "gamma"],
            // Row starts on link (matched). right→move, Enter confirm slug, left→link (defaults to beta), Enter confirm, commit
            bytes: right + enter + left + enter + enter
        )
        let result = try dashboard.run()
        #expect(result == [.linkToShared(sharedID: "beta")])
    }

    @Test("empty sharedIDs makes link unavailable in cycle")
    func emptySharedIDsSkipsLink() throws {
        // With no sharedIDs: import(0)→move(1)→leave(2)→skip(3)
        // right→slug+enter, right→leave, right→skip, Enter commit
        let (dashboard, _) = makeDashboard(
            rows: [row("KEY")],
            sharedIDs: [],
            bytes: right + enter + right + right + enter
        )
        let result = try dashboard.run()
        #expect(result == [.skip])
    }

    @Test("link picker Esc reverts to prior choice")
    func linkPickerEscRevertsChoice() throws {
        let (dashboard, _) = makeDashboard(
            rows: [row("KEY")],
            sharedIDs: ["alpha", "beta"],
            bytes: right + escCancel + enter  // right→link picker, Esc cancel (consumes 0x00), Enter commit
        )
        let result = try dashboard.run()
        #expect(result == [.importAsLocal])
    }

    @Test("link picker renders shared entry list in output")
    func linkPickerRendersEntries() throws {
        let (dashboard, captured) = makeDashboard(
            rows: [row("KEY")],
            sharedIDs: ["alpha", "beta"],
            bytes: right + enter + enter
        )
        _ = try dashboard.run()
        let allOutput = captured().joined()
        #expect(allOutput.contains("alpha"))
        #expect(allOutput.contains("beta"))
    }

    @Test("link picker up/down navigation clamped at both ends")
    func linkPickerNavigationClamped() throws {
        let (dashboard, _) = makeDashboard(
            rows: [row("KEY")],
            sharedIDs: ["only-one"],
            bytes: right + up + down + enter + enter  // up at top and down at bottom both clamp
        )
        let result = try dashboard.run()
        #expect(result == [.linkToShared(sharedID: "only-one")])
    }
}

// MARK: - Move slug field tests

@Suite("IngestDashboard — move slug field")
struct IngestDashboardSlugFieldTests {
    @Test("typing characters and Enter records sanitized slug")
    func typingSlugAndEnterRecords() throws {
        // "my-key" in ASCII
        let slugBytes: [UInt8] = [0x6D, 0x79, 0x2D, 0x6B, 0x65, 0x79]
        let (dashboard, _) = makeDashboard(
            rows: [row("KEY")],
            sharedIDs: [],
            bytes: right + slugBytes + enter + enter
        )
        let result = try dashboard.run()
        #expect(result == [.moveToShared(newSharedID: "my-key")])
    }

    @Test("backspace deletes last character")
    func backspaceDeletesLastChar() throws {
        // "myxx" + BS×2 + "key" = "mykey"
        let bytes: [UInt8] = [0x6D, 0x79, 0x78, 0x78, 0x7F, 0x7F, 0x6B, 0x65, 0x79]
        let (dashboard, _) = makeDashboard(
            rows: [row("KEY")],
            sharedIDs: [],
            bytes: right + bytes + enter + enter
        )
        let result = try dashboard.run()
        #expect(result == [.moveToShared(newSharedID: "mykey")])
    }

    @Test("empty slug falls back to 'scope'")
    func emptySlugFallsBackToScope() throws {
        let (dashboard, _) = makeDashboard(
            rows: [row("KEY")],
            sharedIDs: [],
            bytes: right + enter + enter
        )
        let result = try dashboard.run()
        #expect(result == [.moveToShared(newSharedID: "scope")])
    }

    @Test("stray arrow bytes do not corrupt slug — regression guard for ho-04.2 bug")
    func escapeBytesDoNotCorruptSlug() throws {
        // "hello", up-arrow (ESC [ A), "world", Enter confirm, Enter commit
        let hello: [UInt8] = [0x68, 0x65, 0x6C, 0x6C, 0x6F]
        let world: [UInt8] = [0x77, 0x6F, 0x72, 0x6C, 0x64]
        let upArrow: [UInt8] = [0x1B, 0x5B, 0x41]
        let (dashboard, _) = makeDashboard(
            rows: [row("KEY")],
            sharedIDs: [],
            bytes: right + hello + upArrow + world + enter + enter
        )
        let result = try dashboard.run()
        // Up-arrow bytes consumed and discarded; slug is "helloworld"
        #expect(result == [.moveToShared(newSharedID: "helloworld")])
    }

    @Test("spaces and special characters in slug are sanitized to dashes")
    func slugSanitizesSpecialChars() throws {
        // "My New Entry!!" → "my-new-entry"
        let bytes: [UInt8] = [
            0x4D, 0x79, 0x20, 0x4E, 0x65, 0x77, 0x20, 0x45, 0x6E, 0x74, 0x72, 0x79, 0x21, 0x21,
        ]
        let (dashboard, _) = makeDashboard(
            rows: [row("KEY")],
            sharedIDs: [],
            bytes: right + bytes + enter + enter
        )
        let result = try dashboard.run()
        #expect(result == [.moveToShared(newSharedID: "my-new-entry")])
    }

    @Test("Esc in slug field reverts to prior choice")
    func escInSlugFieldReverts() throws {
        let abc: [UInt8] = [0x61, 0x62, 0x63]
        let (dashboard, _) = makeDashboard(
            rows: [row("KEY")],
            sharedIDs: [],
            bytes: right + abc + escCancel + enter  // right→slug, type "abc", Esc cancel, Enter commit
        )
        let result = try dashboard.run()
        #expect(result == [.importAsLocal])
    }

    @Test("slug field renders current typed text in output")
    func slugFieldRendersText() throws {
        let aChar: [UInt8] = [0x61]
        let (dashboard, captured) = makeDashboard(
            rows: [row("KEY")],
            sharedIDs: [],
            bytes: right + aChar + enter + enter
        )
        _ = try dashboard.run()
        #expect(captured().joined().contains("> a_"))
    }
}

// MARK: - Commit and cancel tests

@Suite("IngestDashboard — commit and cancel")
struct IngestDashboardCommitCancelTests {
    @Test("Enter returns resolved choices for all rows")
    func enterReturnsChoices() throws {
        let (dashboard, _) = makeDashboard(rows: [row("A"), row("B")], bytes: enter)
        let result = try dashboard.run()
        #expect(result.count == 2)
    }

    @Test("q throws CLIError.aborted")
    func qThrowsAborted() throws {
        let (dashboard, _) = makeDashboard(rows: [row("KEY")], bytes: [0x71])
        #expect(throws: CLIError.aborted) { try dashboard.run() }
    }

    @Test("lone Esc in main mode throws CLIError.aborted")
    func loneEscInMainThrowsAborted() throws {
        // Single 0x1B with empty queue — the handler reads nil as the next byte → aborted
        let (dashboard, _) = makeDashboard(rows: [row("KEY")], bytes: escMain)
        #expect(throws: CLIError.aborted) { try dashboard.run() }
    }

    @Test("Ctrl-C throws CLIError.aborted")
    func ctrlCThrowsAborted() throws {
        let (dashboard, _) = makeDashboard(rows: [row("KEY")], bytes: [0x03])
        #expect(throws: CLIError.aborted) { try dashboard.run() }
    }

    @Test("Ctrl-C in ALL picker throws CLIError.aborted")
    func ctrlCInAllPickerThrowsAborted() throws {
        let (dashboard, _) = makeDashboard(rows: [row("KEY")], bytes: aKey + [0x03])
        #expect(throws: CLIError.aborted) { try dashboard.run() }
    }

    @Test("Ctrl-C in link picker throws CLIError.aborted")
    func ctrlCInLinkPickerThrowsAborted() throws {
        let (dashboard, _) = makeDashboard(
            rows: [row("KEY")],
            sharedIDs: ["alpha"],
            bytes: right + [0x03]
        )
        #expect(throws: CLIError.aborted) { try dashboard.run() }
    }

    @Test("Ctrl-C in slug field throws CLIError.aborted")
    func ctrlCInSlugFieldThrowsAborted() throws {
        let (dashboard, _) = makeDashboard(
            rows: [row("KEY")],
            sharedIDs: [],
            bytes: right + [0x03]
        )
        #expect(throws: CLIError.aborted) { try dashboard.run() }
    }
}

// MARK: - Non-TTY refusal tests

@Suite("IngestDashboard — non-TTY refusal")
struct IngestDashboardNonTTYTests {
    @Test("isInteractive false throws notInteractiveTerminal without consuming bytes")
    func nonInteractiveThrows() throws {
        var byteConsumed = false
        var dashboard = IngestDashboard(rows: [row("KEY")], sharedIDs: [], banner: [])
        dashboard.readByte = {
            byteConsumed = true
            return 0x0A
        }
        dashboard.write = { _ in }
        dashboard.isInteractive = { false }
        #expect(throws: CLIError.notInteractiveTerminal) { try dashboard.run() }
        #expect(!byteConsumed)
    }
}

// MARK: - Rendering tests

@Suite("IngestDashboard — rendering")
struct IngestDashboardRenderTests {
    @Test("first write contains smcup escape sequence")
    func firstWriteContainsSmcup() throws {
        let (dashboard, captured) = makeDashboard(rows: [row("KEY")], bytes: enter)
        _ = try dashboard.run()
        #expect(captured().first?.contains("\u{1B}[?1049h") == true)
    }

    @Test("banner lines appear in render output")
    func bannerAppearsInRender() throws {
        let (dashboard, captured) = makeDashboard(
            rows: [row("KEY")],
            banner: ["Keys needing values: FOO, BAR"],
            bytes: enter
        )
        _ = try dashboard.run()
        #expect(captured().joined().contains("Keys needing values: FOO, BAR"))
    }

    @Test("active row is wrapped in bold escape")
    func activeRowIsBold() throws {
        let (dashboard, captured) = makeDashboard(rows: [row("KEY")], bytes: enter)
        _ = try dashboard.run()
        let allOutput = captured().joined()
        #expect(allOutput.contains("\u{1B}[1m"))
        #expect(allOutput.contains("KEY"))
    }

    @Test("cycling through all five choices with sharedIDs does not crash")
    func allFiveChoicesInCycle() throws {
        // import→link(enter)→move(enter)→leave→skip→commit
        let (dashboard, _) = makeDashboard(
            rows: [row("KEY")],
            sharedIDs: ["entry"],
            bytes: right + enter + right + enter + right + right + enter
        )
        let result = try dashboard.run()
        #expect(result == [.skip])
    }
}
