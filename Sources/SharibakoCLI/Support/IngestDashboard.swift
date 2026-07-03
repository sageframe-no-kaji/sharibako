import Foundation

#if canImport(Darwin)
    import Darwin
#endif

// MARK: - Module-level dashboard terminal state (signal-handler-safe)

/// Saved terminal state written before entering raw mode and read by the
/// SIGINT restore handler.  `nil` when no `IngestDashboard` is active.
///
/// `nonisolated(unsafe)` because the SIGINT handler runs outside any Swift
/// actor context.  Access is single-threaded in practice — one dashboard at a
/// time — so no lock is needed.
nonisolated(unsafe) private var _dashboardSavedTermios: termios?

/// Set to `true` immediately after the dashboard enters the alternate screen
/// buffer, cleared before leaving it.
///
/// Read by the SIGINT handler to decide whether to emit `rmcup`.
nonisolated(unsafe) private var _dashboardInAlternateScreen = false

/// C-compatible SIGINT handler: restores raw mode, leaves the alternate screen
/// if active, then re-raises SIGINT so the process exits with conventional
/// signal status.
///
/// Not covered in headless CI — real TTY and SIGINT delivery required.
private func _dashboardSigintRestoreAndReraise(_ signo: CInt) {
    // swiftlint:disable:next identifier_name
    if var t = _dashboardSavedTermios {
        tcsetattr(STDIN_FILENO, TCSANOW, &t)
    }
    if _dashboardInAlternateScreen {
        // ESC [ ? 1 0 4 9 l — rmcup (leave alternate screen buffer).
        // Written via a stack tuple so no heap allocation occurs in the signal handler.
        // swiftlint:disable:next large_tuple
        var rmcup: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x34, 0x39, 0x6C)
        withUnsafeBytes(of: &rmcup) { ptr in
            _ = Darwin.write(STDERR_FILENO, ptr.baseAddress, ptr.count)
        }
        _dashboardInAlternateScreen = false
    }
    signal(SIGINT, SIG_DFL)
    raise(SIGINT)
}

/// Puts stdin into raw, non-echoing mode and installs the SIGINT restore handler.
///
/// No-ops silently when stdin is not a TTY (CI / injected-readByte test path).
/// Not covered in headless CI — real TTY required.
private func _dashboardEnterRawMode() {
    guard isatty(STDIN_FILENO) != 0 else { return }
    // swiftlint:disable:next identifier_name
    var t = termios()
    tcgetattr(STDIN_FILENO, &t)
    _dashboardSavedTermios = t
    t.c_lflag &= ~(UInt(ICANON) | UInt(ECHO))
    withUnsafeMutableBytes(of: &t.c_cc) { ptr in
        ptr[Int(VMIN)] = 1
        ptr[Int(VTIME)] = 0
    }
    tcsetattr(STDIN_FILENO, TCSANOW, &t)
    signal(SIGINT, _dashboardSigintRestoreAndReraise)
}

/// Restores the saved terminal state and removes the SIGINT restore handler.
///
/// No-ops when `_dashboardSavedTermios` is nil (non-TTY path).
/// Not covered in headless CI — real TTY required.
private func _dashboardExitRawMode() {
    // swiftlint:disable:next identifier_name
    if var t = _dashboardSavedTermios {
        tcsetattr(STDIN_FILENO, TCSANOW, &t)
    }
    signal(SIGINT, SIG_DFL)
    _dashboardSavedTermios = nil
}

// MARK: - ResolvedChoice

/// The per-row result returned by `IngestDashboard.run()`.
enum ResolvedChoice: Equatable {
    /// Encrypt and store as a scope-local secret.
    case importAsLocal
    /// Link to an existing shared entry.
    case linkToShared(sharedID: String)
    /// Create a new shared entry with the given ID.
    case moveToShared(newSharedID: String)
    /// Confirmed non-secret; write nothing.
    case leaveAlone
    /// Deferred; write nothing this run.
    case skip
}

// MARK: - IngestDashboard

// swiftlint:disable type_body_length
/// A full-screen, alternate-screen, raw-mode routing table.
///
/// Renders one row per detected key; the user navigates with ↑/↓, cycles each
/// key's choice with ←/→, marks rows with space, bulk-applies a target-free
/// action with `a`, collects the link shared-entry pick and move slug
/// in-dashboard, then commits with Enter or cancels with q / Esc / Ctrl-C.
///
/// ## Testability
///
/// Inject `readByte`, `write`, and `isInteractive` to drive the widget without
/// a real terminal.  The raw-mode and alternate-screen setup gracefully no-ops
/// when stdin is not a TTY.  Only the default `readByte` closure body and the
/// raw-mode functions are coverage-excluded (real TTY required); the entire
/// state machine is reachable through injected bytes.
struct IngestDashboard {
    // MARK: Row

    /// One row in the dashboard — a detected key and its optional name-matched shared entry.
    struct Row {
        /// The key name (e.g. `API_KEY`).
        let key: String
        /// Pre-matched shared entry ID suggested by the Materializer, if any.
        let matchedSharedID: String?
    }

    // MARK: Properties

    /// The rows to display, one per detected key.
    let rows: [Row]
    /// Available shared entry IDs for link choices.
    let sharedIDs: [String]
    /// Read-only context lines shown above the table (needs-values, parse warnings).
    let banner: [String]

    /// Single-byte source.
    ///
    /// Defaults to a blocking raw-mode read from stdin.
    /// Inject a scripted queue in tests; the raw-mode default is not covered
    /// in headless CI.
    var readByte: () -> UInt8? = {
        // Raw-mode single-byte stdin read. Not covered in headless CI.
        var byte: UInt8 = 0
        let result = Darwin.read(STDIN_FILENO, &byte, 1)
        return result == 1 ? byte : nil
    }

    /// Output sink for renders.
    ///
    /// Defaults to stderr (prompts are UX, not payload).
    var write: (String) -> Void = { fputs($0, stderr) }

    /// TTY guard.
    ///
    /// Defaults to `TerminalDetector.isInteractiveInput`.
    var isInteractive: () -> Bool = { TerminalDetector.isInteractiveInput }

    // MARK: Public entry point

    /// Runs the dashboard and returns one `ResolvedChoice` per row (in `rows` order).
    ///
    /// - Throws: `CLIError.notInteractiveTerminal` when stdin is not a TTY;
    ///   `CLIError.aborted` on q / Esc / Ctrl-C.
    func run() throws -> [ResolvedChoice] {
        guard isInteractive() else { throw CLIError.notInteractiveTerminal }
        _dashboardEnterRawMode()
        write("\u{1B}[?1049h\u{1B}[2J\u{1B}[H")  // smcup + clear + home
        _dashboardInAlternateScreen = true
        defer {
            write("\u{1B}[?1049l")  // rmcup
            _dashboardInAlternateScreen = false
            _dashboardExitRawMode()
        }
        return try runStateLoop()
    }

    // MARK: - Private types

    private struct RowState {
        let key: String
        let matchedSharedID: String?
        var choice: RowChoice
        var isMarked: Bool
    }

    // The ordering of categories in the left/right cycle.
    private enum ChoiceCategory: Equatable {
        case importLocal
        case link
        case move
        case leave
        case skip
    }

    private enum RowChoice: Equatable {
        case importAsLocal
        case linkToShared(sharedID: String)
        case moveToShared(newSharedID: String)
        case leaveAlone
        case skip

        var category: ChoiceCategory {
            switch self {
            case .importAsLocal: .importLocal
            case .linkToShared: .link
            case .moveToShared: .move
            case .leaveAlone: .leave
            case .skip: .skip
            }
        }

        var moveSlug: String? {
            if case .moveToShared(let slug) = self { return slug }
            return nil
        }
    }

    /// Interaction sub-mode the dashboard is currently in.
    private enum Mode {
        case main
        case allPicker(selectedIndex: Int)
        case linkPicker(rowIndex: Int, selectedSharedIndex: Int, priorChoice: RowChoice)
        case slugField(rowIndex: Int, priorChoice: RowChoice, slug: String)
    }

    // Ordered target-free choices available in the ALL bulk action.
    private static let bulkChoices: [RowChoice] = [.importAsLocal, .leaveAlone, .skip]
    private static let bulkChoiceLabels: [String] = ["import", "leave", "skip"]

    // MARK: - State machine

    private func runStateLoop() throws -> [ResolvedChoice] {
        var rowStates = buildInitialRowStates()
        var cursor = 0
        var mode: Mode = .main
        renderScreen(rowStates: rowStates, cursor: cursor, mode: mode)
        while true {
            guard let byte = readByte() else { continue }
            if let result = try handleByte(byte, rowStates: &rowStates, cursor: &cursor, mode: &mode) {
                return result
            }
            renderScreen(rowStates: rowStates, cursor: cursor, mode: mode)
        }
    }

    private func buildInitialRowStates() -> [RowState] {
        rows.map { row in
            let choice: RowChoice
            if let matchedID = row.matchedSharedID, !sharedIDs.isEmpty {
                choice = .linkToShared(sharedID: matchedID)
            } else {
                choice = .importAsLocal
            }
            return RowState(key: row.key, matchedSharedID: row.matchedSharedID, choice: choice, isMarked: false)
        }
    }

    private func handleByte(
        _ byte: UInt8,
        rowStates: inout [RowState],
        cursor: inout Int,
        mode: inout Mode
    ) throws -> [ResolvedChoice]? {
        switch mode {
        case .main:
            return try handleMainByte(byte, rowStates: &rowStates, cursor: &cursor, mode: &mode)
        case .allPicker(let idx):
            try handleAllPickerByte(byte, selectedIndex: idx, rowStates: &rowStates, mode: &mode)
        // swiftlint:disable:next pattern_matching_keywords
        case .linkPicker(let rowIdx, let sharedIdx, let prior):
            try handleLinkPickerByte(
                byte, rowIndex: rowIdx, sharedIndex: sharedIdx, priorChoice: prior, rowStates: &rowStates, mode: &mode)
        // swiftlint:disable:next pattern_matching_keywords
        case .slugField(let rowIdx, let prior, let slug):
            try handleSlugFieldByte(
                byte, rowIndex: rowIdx, priorChoice: prior, slug: slug, rowStates: &rowStates, mode: &mode)
        }
        return nil
    }

    private func handleMainByte(
        _ byte: UInt8,
        rowStates: inout [RowState],
        cursor: inout Int,
        mode: inout Mode
    ) throws -> [ResolvedChoice]? {
        switch byte {
        case 0x03:
            throw CLIError.aborted
        case 0x0A, 0x0D:
            return rowStates.map { resolvedChoice(from: $0.choice) }
        case 0x71:  // q
            throw CLIError.aborted
        case 0x20:  // space
            if !rowStates.isEmpty { rowStates[cursor].isMarked.toggle() }
        case 0x61:  // a
            mode = .allPicker(selectedIndex: 0)
        case 0x1B:
            try handleEscSequenceInMain(cursor: &cursor, rowStates: &rowStates, mode: &mode)
        default:
            break
        }
        return nil
    }

    private func handleEscSequenceInMain(
        cursor: inout Int,
        rowStates: inout [RowState],
        mode: inout Mode
    ) throws {
        guard let next = readByte(), next == 0x5B else { throw CLIError.aborted }
        guard let arrowByte = readByte() else { return }
        switch arrowByte {
        case 0x41 where cursor > 0:
            cursor -= 1
        case 0x42 where cursor < rowStates.count - 1:
            cursor += 1
        case 0x43:
            cycleChoice(rowIndex: cursor, rowStates: &rowStates, direction: 1, mode: &mode)
        case 0x44:
            cycleChoice(rowIndex: cursor, rowStates: &rowStates, direction: -1, mode: &mode)
        default:
            break
        }
    }

    private func handleAllPickerByte(
        _ byte: UInt8,
        selectedIndex: Int,
        rowStates: inout [RowState],
        mode: inout Mode
    ) throws {
        switch byte {
        case 0x03:
            throw CLIError.aborted
        case 0x0A, 0x0D:
            let choice = Self.bulkChoices[selectedIndex]
            let markedIndices = rowStates.indices.filter { rowStates[$0].isMarked }
            let targets = markedIndices.isEmpty ? Array(rowStates.indices) : markedIndices
            for idx in targets {
                rowStates[idx].choice = choice
                rowStates[idx].isMarked = false
            }
            mode = .main
        case 0x1B:
            let next = readByte()
            if next == 0x5B {
                let arrow = readByte()
                switch arrow {
                case 0x41:
                    mode = .allPicker(selectedIndex: max(0, selectedIndex - 1))
                case 0x42:
                    mode = .allPicker(selectedIndex: min(Self.bulkChoices.count - 1, selectedIndex + 1))
                default:
                    break
                }
            } else {
                mode = .main
            }
        default:
            break
        }
    }

    // swiftlint:disable:next function_parameter_count
    private func handleLinkPickerByte(
        _ byte: UInt8,
        rowIndex: Int,
        sharedIndex: Int,
        priorChoice: RowChoice,
        rowStates: inout [RowState],
        mode: inout Mode
    ) throws {
        switch byte {
        case 0x03:
            throw CLIError.aborted
        case 0x0A, 0x0D:
            rowStates[rowIndex].choice = .linkToShared(sharedID: sharedIDs[sharedIndex])
            mode = .main
        case 0x1B:
            let next = readByte()
            if next == 0x5B {
                let arrow = readByte()
                switch arrow {
                case 0x41:
                    mode = .linkPicker(
                        rowIndex: rowIndex, selectedSharedIndex: max(0, sharedIndex - 1), priorChoice: priorChoice)
                case 0x42:
                    mode = .linkPicker(
                        rowIndex: rowIndex,
                        selectedSharedIndex: min(sharedIDs.count - 1, sharedIndex + 1),
                        priorChoice: priorChoice
                    )
                default:
                    break
                }
            } else {
                rowStates[rowIndex].choice = priorChoice
                mode = .main
            }
        default:
            break
        }
    }

    // swiftlint:disable:next function_parameter_count
    private func handleSlugFieldByte(
        _ byte: UInt8,
        rowIndex: Int,
        priorChoice: RowChoice,
        slug: String,
        rowStates: inout [RowState],
        mode: inout Mode
    ) throws {
        switch byte {
        case 0x03:
            throw CLIError.aborted
        case 0x0A, 0x0D:
            let sanitized = sanitizeSharedID(slug)
            rowStates[rowIndex].choice = .moveToShared(newSharedID: sanitized)
            mode = .main
        case 0x7F, 0x08:  // DEL / BS
            var updated = slug
            if !updated.isEmpty { updated.removeLast() }
            mode = .slugField(rowIndex: rowIndex, priorChoice: priorChoice, slug: updated)
        case 0x1B:
            // Consume any following escape sequence so bytes do not corrupt the slug.
            // Regression guard for the ho-04.2 bug where a bare readLine() picked up
            // buffered arrow-key bytes after raw mode.
            let next = readByte()
            if next == 0x5B {
                _ = readByte()  // discard arrow direction byte
            } else {
                // Lone Esc: cancel slug field, revert to prior choice.
                rowStates[rowIndex].choice = priorChoice
                mode = .main
            }
        case 0x20...0x7E:  // printable ASCII (excluding DEL at 0x7F)
            let char = String(UnicodeScalar(byte))
            mode = .slugField(rowIndex: rowIndex, priorChoice: priorChoice, slug: slug + char)
        default:
            break
        }
    }

    // MARK: - Cycle

    private func cycleChoice(
        rowIndex: Int,
        rowStates: inout [RowState],
        direction: Int,
        mode: inout Mode
    ) {
        let cats = availableCategories()
        let currentCat = rowStates[rowIndex].choice.category
        let currentIdx = cats.firstIndex(of: currentCat) ?? 0
        let nextIdx = ((currentIdx + direction) % cats.count + cats.count) % cats.count
        let prior = rowStates[rowIndex].choice
        switch cats[nextIdx] {
        case .importLocal:
            rowStates[rowIndex].choice = .importAsLocal
        case .link:
            let defaultIdx = defaultSharedIndex(matchedID: rowStates[rowIndex].matchedSharedID)
            mode = .linkPicker(rowIndex: rowIndex, selectedSharedIndex: defaultIdx, priorChoice: prior)
        case .move:
            let existingSlug = prior.moveSlug ?? ""
            mode = .slugField(rowIndex: rowIndex, priorChoice: prior, slug: existingSlug)
        case .leave:
            rowStates[rowIndex].choice = .leaveAlone
        case .skip:
            rowStates[rowIndex].choice = .skip
        }
    }

    private func availableCategories() -> [ChoiceCategory] {
        var cats: [ChoiceCategory] = [.importLocal]
        if !sharedIDs.isEmpty { cats.append(.link) }
        cats.append(.move)
        cats.append(.leave)
        cats.append(.skip)
        return cats
    }

    private func defaultSharedIndex(matchedID: String?) -> Int {
        guard let matched = matchedID else { return 0 }
        return sharedIDs.firstIndex(of: matched) ?? 0
    }

    private func resolvedChoice(from rowChoice: RowChoice) -> ResolvedChoice {
        switch rowChoice {
        case .importAsLocal: .importAsLocal
        case .linkToShared(let id): .linkToShared(sharedID: id)
        case .moveToShared(let slug): .moveToShared(newSharedID: slug)
        case .leaveAlone: .leaveAlone
        case .skip: .skip
        }
    }

    // MARK: - Rendering

    private func renderScreen(rowStates: [RowState], cursor: Int, mode: Mode) {
        var out = "\u{1B}[2J\u{1B}[H"
        out += renderBanner()
        let maxKeyLen = rowStates.map(\.key.count).max() ?? 0
        for (idx, row) in rowStates.enumerated() {
            out += renderRow(row, isActive: idx == cursor, maxKeyLen: maxKeyLen)
        }
        out += "\r\n"
        switch mode {
        case .main:
            out += renderMainFooter()
        case .allPicker(let idx):
            out += renderAllPicker(selectedIndex: idx)
        // swiftlint:disable:next pattern_matching_keywords
        case .linkPicker(let rowIdx, let sharedIdx, _):
            out += renderLinkPicker(rowIndex: rowIdx, selectedSharedIndex: sharedIdx)
        // swiftlint:disable:next pattern_matching_keywords
        case .slugField(let rowIdx, _, let slug):
            out += renderSlugField(rowIndex: rowIdx, slug: slug)
        }
        write(out)
    }

    private func renderBanner() -> String {
        guard !banner.isEmpty else { return "" }
        var out = ""
        for line in banner { out += line + "\r\n" }
        out += "\r\n"
        return out
    }

    private func renderRow(_ row: RowState, isActive: Bool, maxKeyLen: Int) -> String {
        let activeGlyph = isActive ? "→" : " "
        let markGlyph = row.isMarked ? "[*]" : "[ ]"
        let keyPadded = row.key.padding(toLength: maxKeyLen, withPad: " ", startingAt: 0)
        let choiceStr = choiceLabel(row.choice)
        let line = "\(activeGlyph) \(markGlyph) \(keyPadded)  \(choiceStr)"
        if isActive {
            return "\u{1B}[1m\(line)\u{1B}[0m\r\n"
        }
        return line + "\r\n"
    }

    private func choiceLabel(_ choice: RowChoice) -> String {
        switch choice {
        case .importAsLocal:
            return "\u{1B}[32m✓ import\u{1B}[0m"
        case .linkToShared(let id):
            return "\u{1B}[36m✓ link (\(id))\u{1B}[0m"
        case .moveToShared(let slug):
            let display = slug.isEmpty ? "(slug below)" : slug
            return "\u{1B}[36m✓ move → \(display)\u{1B}[0m"
        case .leaveAlone:
            return "\u{1B}[33m  leave\u{1B}[0m"
        case .skip:
            return "\u{1B}[2m  skip\u{1B}[0m"
        }
    }

    private func renderMainFooter() -> String {
        "↑↓ navigate  ←→ cycle choice  space mark  a bulk  Enter commit  q cancel\r\n"
    }

    private func renderAllPicker(selectedIndex: Int) -> String {
        var out = "── Bulk action (applies to marked rows, or all when none marked) ──\r\n"
        for (idx, label) in Self.bulkChoiceLabels.enumerated() {
            let marker = idx == selectedIndex ? "→ " : "  "
            out += "\(marker)\(label)\r\n"
        }
        out += "↑↓ select  Enter apply  Esc cancel\r\n"
        return out
    }

    private func renderLinkPicker(rowIndex: Int, selectedSharedIndex: Int) -> String {
        let keyName = rows[rowIndex].key
        var out = "── Link \(keyName) to: ──\r\n"
        for (idx, entry) in sharedIDs.enumerated() {
            let marker = idx == selectedSharedIndex ? "→ " : "  "
            out += "\(marker)\(entry)\r\n"
        }
        out += "↑↓ select  Enter confirm  Esc cancel\r\n"
        return out
    }

    private func renderSlugField(rowIndex: Int, slug: String) -> String {
        let keyName = rows[rowIndex].key
        return "── New shared entry ID for \(keyName): ──\r\n> \(slug)_\r\nType slug  Enter confirm  Esc cancel\r\n"
    }
}
// swiftlint:enable type_body_length

// MARK: - Slug sanitizer
//
// Local copy of the sanitize rules from InteractiveIngestPrompt (to be deleted in AT-02).
// Must remain identical to `sanitizeSharedID` in that file until it is removed.
// If these rules ever diverge from SharibakoCore's scope-ID rules, factor a
// public helper on SharibakoCore rather than maintaining two copies.

private func sanitizeSharedID(_ raw: String) -> String {
    let lower = raw.lowercased()
    var mapped = ""
    for scalar in lower.unicodeScalars {
        let isLower = scalar.value >= 0x61 && scalar.value <= 0x7A
        let isDigit = scalar.value >= 0x30 && scalar.value <= 0x39
        let isDash = scalar.value == 0x2D
        if isLower || isDigit || isDash {
            mapped.unicodeScalars.append(scalar)
        } else {
            mapped.append("-")
        }
    }
    var collapsed = ""
    var lastWasDash = false
    for char in mapped {
        if char == "-" {
            if lastWasDash { continue }
            lastWasDash = true
        } else {
            lastWasDash = false
        }
        collapsed.append(char)
    }
    while collapsed.hasPrefix("-") { collapsed.removeFirst() }
    while collapsed.hasSuffix("-") { collapsed.removeLast() }
    return collapsed.isEmpty ? "scope" : collapsed
}
