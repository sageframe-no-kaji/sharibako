import Foundation
import Testing

@testable import SharibakoCLI

// MARK: - Helpers

private func makeSelect(
    choices: [String] = ["alpha", "beta", "gamma"],
    title: String = "Pick:",
    initialIndex: Int = 0,
    bytes: [UInt8],
    frames: inout [String]
) -> InteractiveSelect {
    var queue = bytes
    var captured: [String] = []
    var select = InteractiveSelect(
        title: title,
        choices: choices,
        initialIndex: initialIndex
    )
    select.readByte = { queue.isEmpty ? nil : queue.removeFirst() }
    select.write = { captured.append($0) }
    select.isInteractive = { true }
    frames = captured
    return select
}

// MARK: - Tests

@Suite("InteractiveSelect — state machine")
struct InteractiveSelectTests {
    // MARK: Basic navigation

    @Test("enter-at-top returns index 0")
    func enterAtTop() throws {
        var frames: [String] = []
        var select = makeSelect(
            choices: ["alpha", "beta"],
            bytes: [0x0A],
            frames: &frames
        )
        // Capture is populated lazily during run; reassign write to populate our
        // local array while referencing the same underlying storage.
        var captured: [String] = []
        select.write = { captured.append($0) }
        let result = try select.run()
        #expect(result == 0)
        // One frame rendered (initial only — no movement before Enter).
        #expect(captured.count == 1)
    }

    @Test("down then enter returns index 1")
    func downThenEnter() throws {
        let downArrow: [UInt8] = [0x1B, 0x5B, 0x42]
        let enter: [UInt8] = [0x0A]
        var captured: [String] = []
        var select = InteractiveSelect(title: "Pick:", choices: ["alpha", "beta", "gamma"])
        var queue = downArrow + enter
        select.readByte = { queue.isEmpty ? nil : queue.removeFirst() }
        select.write = { captured.append($0) }
        select.isInteractive = { true }

        let result = try select.run()
        #expect(result == 1)
        // Two frames: initial + one redraw after the down arrow.
        #expect(captured.count == 2)
    }

    @Test("down-down-up-enter returns index 1")
    func downDownUpEnter() throws {
        let down: [UInt8] = [0x1B, 0x5B, 0x42]
        let up: [UInt8] = [0x1B, 0x5B, 0x41]
        let enter: [UInt8] = [0x0A]
        var captured: [String] = []
        var select = InteractiveSelect(title: "Pick:", choices: ["alpha", "beta", "gamma"])
        var queue = down + down + up + enter
        select.readByte = { queue.isEmpty ? nil : queue.removeFirst() }
        select.write = { captured.append($0) }
        select.isInteractive = { true }

        let result = try select.run()
        #expect(result == 1)
        // Cursor path: 0→1→2→1; three redraws + initial = 4 frames.
        #expect(captured.count == 4)
    }

    // MARK: Clamping

    @Test("up at top stays at 0 (no redraw)")
    func upAtTopClamped() throws {
        let up: [UInt8] = [0x1B, 0x5B, 0x41]
        let enter: [UInt8] = [0x0A]
        var captured: [String] = []
        var select = InteractiveSelect(title: "Pick:", choices: ["alpha", "beta"])
        var queue = up + enter
        select.readByte = { queue.isEmpty ? nil : queue.removeFirst() }
        select.write = { captured.append($0) }
        select.isInteractive = { true }

        let result = try select.run()
        #expect(result == 0)
        // No redraw because cursor did not move.
        #expect(captured.count == 1)
    }

    @Test("down at bottom clamps (no extra redraw)")
    func downAtBottomClamped() throws {
        let down: [UInt8] = [0x1B, 0x5B, 0x42]
        let enter: [UInt8] = [0x0A]
        var captured: [String] = []
        var select = InteractiveSelect(title: "Pick:", choices: ["alpha", "beta"])
        // down, down (clamp), enter
        var queue = down + down + enter
        select.readByte = { queue.isEmpty ? nil : queue.removeFirst() }
        select.write = { captured.append($0) }
        select.isInteractive = { true }

        let result = try select.run()
        #expect(result == 1)
        // Cursor: 0→1 (redraw), 1→1 (no redraw), enter.  2 frames total.
        #expect(captured.count == 2)
    }

    @Test("initialIndex respected at entry")
    func initialIndexRespected() throws {
        let enter: [UInt8] = [0x0A]
        var captured: [String] = []
        var select = InteractiveSelect(
            title: "Pick:",
            choices: ["alpha", "beta", "gamma"],
            initialIndex: 2
        )
        var queue = enter
        select.readByte = { queue.isEmpty ? nil : queue.removeFirst() }
        select.write = { captured.append($0) }
        select.isInteractive = { true }

        let result = try select.run()
        #expect(result == 2)
    }

    // MARK: Ctrl-C

    @Test("Ctrl-C throws CLIError.aborted")
    func ctrlCThrowsAborted() throws {
        var captured: [String] = []
        var select = InteractiveSelect(title: "Pick:", choices: ["alpha", "beta"])
        var queue: [UInt8] = [0x03]
        select.readByte = { queue.isEmpty ? nil : queue.removeFirst() }
        select.write = { captured.append($0) }
        select.isInteractive = { true }

        #expect(throws: CLIError.aborted) {
            try select.run()
        }
    }

    // MARK: Non-TTY refusal

    @Test("non-interactive throws notInteractiveTerminal without reading bytes")
    func nonInteractiveThrows() throws {
        var byteConsumed = false
        var select = InteractiveSelect(title: "Pick:", choices: ["alpha", "beta"])
        select.readByte = {
            byteConsumed = true
            return 0x0A
        }
        select.write = { _ in }
        select.isInteractive = { false }

        #expect(throws: CLIError.notInteractiveTerminal) {
            try select.run()
        }
        #expect(!byteConsumed)
    }

    // MARK: Rendered frames

    @Test("highlight tracks cursor through down arrow")
    func highlightTracksCursor() throws {
        let down: [UInt8] = [0x1B, 0x5B, 0x42]
        let enter: [UInt8] = [0x0A]
        var captured: [String] = []
        var select = InteractiveSelect(title: "Pick:", choices: ["alpha", "beta"])
        var queue = down + enter
        select.readByte = { queue.isEmpty ? nil : queue.removeFirst() }
        select.write = { captured.append($0) }
        select.isInteractive = { true }

        _ = try select.run()

        // Frame 0: alpha is highlighted, beta is plain.
        #expect(captured[0].contains("\u{1B}[7m> alpha\u{1B}[0m"))
        #expect(!captured[0].contains("\u{1B}[7m> beta"))

        // Frame 1 (redraw): alpha is plain, beta is highlighted.
        #expect(captured[1].contains("  alpha"))
        #expect(captured[1].contains("\u{1B}[7m> beta\u{1B}[0m"))
    }

    @Test("redraw frame contains move-up escape before title")
    func redrawContainsMoveUp() throws {
        let down: [UInt8] = [0x1B, 0x5B, 0x42]
        let enter: [UInt8] = [0x0A]
        var captured: [String] = []
        var select = InteractiveSelect(title: "T:", choices: ["x", "y", "z"])
        var queue = down + enter
        select.readByte = { queue.isEmpty ? nil : queue.removeFirst() }
        select.write = { captured.append($0) }
        select.isInteractive = { true }

        _ = try select.run()

        // Redraw frame (frame 1) starts with cursor-up sequence.
        // Move up by choices.count (3) lines.
        #expect(captured[1].hasPrefix("\u{1B}[3A"))
    }

    @Test("unrecognized plain byte is ignored")
    func unknownPlainByteIgnored() throws {
        // 'x' (0x78) hits the state machine's default arm; Enter then confirms.
        var captured: [String] = []
        var select = InteractiveSelect(title: "T:", choices: ["x", "y"])
        var queue: [UInt8] = [0x78, 0x0A]
        select.readByte = { queue.isEmpty ? nil : queue.removeFirst() }
        select.write = { captured.append($0) }
        select.isInteractive = { true }

        let result = try select.run()
        #expect(result == 0)  // cursor never moved
        #expect(captured.count == 1)  // no redraw
    }

    @Test("nil read is skipped and the next byte still lands")
    func nilReadSkipped() throws {
        // First read yields nil (EINTR-ish); the loop must continue, not bail.
        var captured: [String] = []
        var select = InteractiveSelect(title: "T:", choices: ["x", "y"])
        var queue: [UInt8?] = [nil, 0x0A]
        select.readByte = { queue.isEmpty ? nil : queue.removeFirst() }
        select.write = { captured.append($0) }
        select.isInteractive = { true }

        let result = try select.run()
        #expect(result == 0)
    }

    @Test("unknown escape byte is ignored")
    func unknownEscapeIgnored() throws {
        // ESC [ C (right arrow — not handled) then Enter
        let rightArrow: [UInt8] = [0x1B, 0x5B, 0x43]
        let enter: [UInt8] = [0x0A]
        var captured: [String] = []
        var select = InteractiveSelect(title: "T:", choices: ["x", "y"])
        var queue = rightArrow + enter
        select.readByte = { queue.isEmpty ? nil : queue.removeFirst() }
        select.write = { captured.append($0) }
        select.isInteractive = { true }

        let result = try select.run()
        #expect(result == 0)  // cursor stayed at 0
        #expect(captured.count == 1)  // no redraw
    }
}
