import Foundation
import SharibakoCore

/// The words and reads the project-first views render (ho-06.9 AT-02,
/// Decisions 8–9).
///
/// `ProjectSidebar`, `ProjectHeader`, and the three status pages
/// (`NotProtectedPage`, `ProblemPage`, `SharedSecretPage`) are declarative
/// and coverage-excluded, so every count-aware phrase and every fallback
/// lives here, tested, rather than in a `View` body. Each string is built
/// from kamae-2.3 §2's ten words. What to load when the selection changes
/// (``loadContent(for:)``) moved to `WorkshopModel+Lines.swift` with the
/// lines it fills (ho-06.10 AT-02).
///
/// Pure reads over state `WorkshopModel.swift` already owns. Kept
/// in its own file, the `Conduit`/`Conduit+Remote.swift` split precedent, so
/// `WorkshopModel.swift` stays under SwiftLint's `file_length` ceiling.
extension WorkshopModel {
    // MARK: - The selected row

    /// The row behind ``selection``, or `nil` when nothing is selected or the
    /// selected thing has gone (protected, forgotten, or deleted since it was
    /// picked).
    ///
    /// The content column renders a page only while this is non-`nil`, so a
    /// row that vanishes under the selection never leaves its page behind.
    var selectedEntry: ProjectEntry? {
        selection.flatMap { projectEntry(for: $0) }
    }

    /// The content column's navigation title: the selected row's name, or
    /// "Projects" with nothing selected (Discovery: the title moves off the
    /// scope ID and onto the project's name, for every kind of row).
    var selectionTitle: String {
        selectedEntry?.name ?? "Projects"
    }

    // MARK: - Project header (Decision 9)

    /// The header's drift clause for `status` — "1 line differs" or "N lines
    /// differ" for an Out-of-date project, `nil` for every other status.
    static func headerDriftClause(for status: ProjectStatus) -> String? {
        guard case .outOfDate(let keyCount) = status else { return nil }
        return keyCount == 1 ? "1 line differs" : "\(keyCount) lines differ"
    }

    /// The header's location line for `entry`: its folder abbreviated against
    /// `home`, or "No folder on this Mac" when it has none.
    ///
    /// `nil` for a No-folder-here project: its status word already says
    /// exactly that, and the header would otherwise repeat it on the line
    /// beneath.
    func headerLocation(for entry: ProjectEntry) -> String? {
        if let directory = entry.directory {
            return abbreviatedPath(directory)
        }
        return entry.status == .noFolderHere ? nil : ProjectStatus.noFolderHere.label
    }

    // MARK: - Not-protected page

    /// The Not-protected page's count line: "N lines in .env", count-aware.
    static func envLineCount(_ count: Int) -> String {
        switch count {
        case 0: return "No lines with a value in .env"
        case 1: return "1 line in .env"
        default: return "\(count) lines in .env"
        }
    }

    // MARK: - Problem page

    /// The Problem page's explanation for a folder claiming project `name`,
    /// as two paragraphs — verbatim from the ho-06.9 drawing.
    static func problemExplanation(projectName name: String) -> [String] {
        [
            "This folder says it belongs to a project called \(name), but the vault has no project "
                + "by that name. It may have been deleted, or the folder came from another machine.",
            "Protect this folder brings its .env into the vault as \(name). Forget this folder "
                + "removes the claim file and leaves everything else alone.",
        ]
    }

    /// The Problem page's title for an unreadable claim file.
    static let unreadableClaimTitle = "Unreadable claim file"

    /// The Problem page's lead-in for an unreadable claim file; the load
    /// failure's reason follows it in monospace.
    static let unreadableClaimLead = "Sharibako could not read the `.sharibako` file in this folder:"

    // MARK: - Shared-secret page

    /// The used-by heading for `sharedID`: "Used by N project(s):", or "Not
    /// used by any project yet." when nothing links to it.
    func usedByHeading(sharedID: String) -> String {
        let count = Set(usedBy(sharedID: sharedID).map(\.scopeID)).count
        switch count {
        case 0: return "Not used by any project yet."
        case 1: return "Used by 1 project:"
        default: return "Used by \(count) projects:"
        }
    }

    /// The used-by list for `sharedID`, one line per use.
    ///
    /// Each line reads "<project> (<KEY>)", in ``usedBy(sharedID:)``'s order.
    func usedByLines(sharedID: String) -> [String] {
        usedBy(sharedID: sharedID).map { "\($0.scopeID) (\($0.key))" }
    }

    /// The shared-secret page's closing note: what a shared secret is, and
    /// that editing it is not here yet.
    static let sharedSecretNote =
        "Changing a shared secret once changes it for every project that uses it. "
        + "Editing shared secrets arrives with linking."

    // MARK: - First-run finish page (Decision 5)

    /// The first-run finish page's preview line for `count` folders found
    /// with a `.env` — they wait under Not protected once the vault exists.
    static func firstRunCandidateSummary(count: Int) -> String {
        count == 1
            ? "Found 1 project with a .env — it'll be waiting under Not protected."
            : "Found \(count) projects with a .env — they'll be waiting under Not protected."
    }
}

extension WorkshopModel.ProjectEntry {
    /// `true` for a Shared-secrets row, whose ``status`` is a placeholder the
    /// views must never render.
    var isShared: Bool {
        if case .shared = id { return true }
        return false
    }

    /// The claim file behind a Needs-attention row.
    ///
    /// The `.problem` status's payload — the Problem page's input — or `nil`
    /// for every other row.
    var problemMarker: WorkshopModel.UnlinkedMarker? {
        if case .problem(let marker) = status { return marker }
        return nil
    }

    /// The row's leading SF Symbol (Decision 8): its status's shape, or
    /// `link` for a shared secret.
    var glyphSymbolName: String {
        isShared ? "link" : status.symbolName
    }

    /// The row's tooltip: its status in the ten words, or what a shared
    /// secret is — never the shared row's placeholder status.
    var glyphHelp: String {
        isShared
            ? "Shared secret — one secret used by several projects; change it once"
            : status.helpText
    }
}
