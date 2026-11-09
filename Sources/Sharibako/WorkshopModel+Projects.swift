import Foundation
import SharibakoCore

/// The project-first read of the vault (ho-06.9 Decisions 1–4, kamae-2.3 §1–3).
///
/// The Workshop's primary noun is the user's *project*, not the vault's
/// *scope*. Everything here is derived, never stored: a ``ProjectEntry`` is
/// computed on read from four caches `WorkshopModel.swift` already owns —
/// ``WorkshopModel/scopes``, ``WorkshopModel/scanReport``,
/// ``WorkshopModel/driftReports``, and ``WorkshopModel/candidates`` — plus
/// ``WorkshopModel/sharedIDs`` for the shared-secrets section. Nothing here
/// walks the tree, decrypts, or touches an age key, so the sidebar costs
/// nothing to render. A page's lines are `WorkshopModel+Lines.swift`'s.
///
/// The five statuses fold together what three older reads expressed apart:
/// ho-06.2's marker-presence glyph (`GlyphState`), its drift badge
/// (`DriftBadge`), and the "Unlinked markers" rows — one status per row, one
/// word for it from kamae-2.3 §2's ten.
///
/// Kept in its own file, the `Conduit`/`Conduit+Remote.swift` split
/// precedent, so `WorkshopModel.swift` stays under SwiftLint's `file_length`
/// ceiling.
extension WorkshopModel {
    // MARK: - Selection

    /// What the sidebar has selected: one of four kinds of row (Decision 1).
    ///
    /// Each case carries the smallest stable identity for its row — a vault
    /// scope ID, a folder URL, a claim-file path, a shared-secret ID — so the
    /// sidebar's `List` can tag rows with it directly and the content column
    /// can switch on it.
    enum Selection: Hashable {
        /// A project in the vault, by its scope ID.
        case project(scopeID: String)
        /// A folder under the scan roots with a `.env` and no claim file yet.
        case candidate(directory: URL)
        /// A folder whose claim file names a project the vault does not have,
        /// or whose claim file cannot be read — by the claim file's path.
        case problem(markerPath: String)
        /// A shared secret, by its ID.
        case shared(id: String)
    }

    // MARK: - Status

    /// Where a project stands, in the user's words (kamae-2.3 §3).
    ///
    /// Shape carries the status, not color alone (colorblind-safe, ho-06.2's
    /// rule kept): each case has a distinct symbol, and the palette token is
    /// the view's choice (Decision 8).
    enum ProjectStatus: Equatable {
        /// A folder with a `.env` and nothing in the vault.
        case notProtected
        /// In the vault, folder present, and — when a check has run — every
        /// secret in `.env` matches the vault.
        case protected
        /// In the vault, folder present, and the last check found
        /// `keyCount` secrets in `.env` that differ from the vault.
        case outOfDate(keyCount: Int)
        /// A claim file the vault cannot place — a project it does not have,
        /// or a claim file that will not load. Carries the marker as payload
        /// so the page and its verbs know which.
        case problem(UnlinkedMarker)
        /// In the vault with no folder on this Mac: a server, a machine, or a
        /// project that lives on another computer.
        case noFolderHere

        /// SF Symbol for the row's leading glyph (Decision 8).
        var symbolName: String {
            switch self {
            case .notProtected: return "circle"
            case .protected: return "checkmark.circle.fill"
            case .outOfDate: return "exclamationmark.triangle.fill"
            case .problem: return "questionmark.circle"
            case .noFolderHere: return "circle.dotted"
            }
        }

        /// The status word — one of the five statuses in the ten words.
        var label: String {
            switch self {
            case .notProtected: return "Not protected"
            case .protected: return "Protected"
            case .outOfDate: return "Out of date"
            case .problem: return "Problem"
            case .noFolderHere: return "No folder on this Mac"
            }
        }

        /// The row's tooltip: the status word and what it means, plainly.
        var helpText: String {
            switch self {
            case .notProtected:
                return "Not protected — this folder has a .env and nothing in the vault yet"
            case .protected:
                return "Protected — in the vault, with its folder on this Mac"
            case .outOfDate(let keyCount):
                let secrets = keyCount == 1 ? "1 secret in .env differs" : "\(keyCount) secrets in .env differ"
                return "Out of date — \(secrets) from the vault"
            case .problem(.orphaned(let name, _)):
                return "Problem — this folder says it belongs to \(name), which the vault does not have"
            case .problem(.failed):
                return "Problem — this folder's claim file can't be read"
            case .noFolderHere:
                return "No folder on this Mac — in the vault, with no folder under the scan roots"
            }
        }
    }

    // MARK: - Entries and sections

    /// One sidebar row, derived (Decision 2).
    struct ProjectEntry: Identifiable, Equatable {
        /// The row's selection identity — also its `List` tag.
        let id: Selection
        /// The row's label: a project's display name, a folder's name, or a
        /// shared secret's ID.
        let name: String
        /// The folder on this Mac, when there is one.
        let directory: URL?
        /// The vault scope behind the row, for `.project` rows only.
        let scopeID: String?
        /// The row's status.
        ///
        /// Shared-secret rows carry `.protected` as a placeholder only — the
        /// section is a pool, not a list of projects, and its rows render no
        /// status (Decision 2). Views must not show it.
        let status: ProjectStatus
    }

    /// The four sidebar sections, in their fixed display order.
    ///
    /// Declared beside ``ProjectSection`` rather than inside it: SwiftLint's
    /// `nesting` rule allows one level below `WorkshopModel`, and a
    /// `ProjectSection.Kind` would be the second.
    enum ProjectSectionKind: CaseIterable {
        /// Folders with a `.env` and nothing in the vault.
        case notProtected
        /// Every project in the vault.
        case projects
        /// Claim files the vault cannot place.
        case needsAttention
        /// The shared-secret pool.
        case sharedSecrets
    }

    /// One sidebar section: a fixed kind and its rows (Decision 2).
    struct ProjectSection: Identifiable, Equatable {
        /// The section's kind — also its stable identity.
        let id: ProjectSectionKind
        /// The section's rows, in display order.
        let entries: [ProjectEntry]

        /// The section header text.
        var title: String {
            switch id {
            case .notProtected: return "Not protected"
            case .projects: return "Projects"
            case .needsAttention: return "Needs attention"
            case .sharedSecrets: return "Shared secrets"
            }
        }
    }

    /// The sidebar's sections, in fixed order — Not protected, Projects,
    /// Needs attention, Shared secrets — with empty sections omitted.
    ///
    /// Pure over current state: no worker, no Touch ID, no filesystem. An
    /// entirely empty result (no vault content and nothing found to protect)
    /// is the view's cue for its one empty state (Decision 2).
    var projectSections: [ProjectSection] {
        let byKind: [(ProjectSectionKind, [ProjectEntry])] = [
            (.notProtected, notProtectedEntries),
            (.projects, projectEntries),
            (.needsAttention, needsAttentionEntries),
            (.sharedSecrets, sharedSecretEntries),
        ]
        return byKind.compactMap { kind, entries in
            entries.isEmpty ? nil : ProjectSection(id: kind, entries: entries)
        }
    }

    /// The status of the vault project `scopeID` (Decision 2).
    ///
    /// Out of date when the drift cache holds a drifted report for it (the
    /// check found differences — that outranks marker presence, since only a
    /// project with a folder can be checked); else Protected when the scan
    /// cache holds its claim file; else No folder on this Mac — including the
    /// cold-cache case, the honest pre-scan answer. Cache reads only.
    func projectStatus(forScope scopeID: String) -> ProjectStatus {
        if let report = driftReports[scopeID], Self.isDrifted(report) {
            return .outOfDate(keyCount: Self.driftedKeyCount(report))
        }
        return cachedMarker(forScope: scopeID) == nil ? .noFolderHere : .protected
    }

    /// The row for `selection`, or `nil` when no current row matches — the
    /// selected thing was protected, forgotten, or deleted since it was picked.
    func projectEntry(for selection: Selection) -> ProjectEntry? {
        for section in projectSections {
            if let entry = section.entries.first(where: { $0.id == selection }) {
                return entry
            }
        }
        return nil
    }

    /// The launch selection rule (Decision 4): the first Not-protected row,
    /// else the first project, else nothing.
    ///
    /// Static and pure so the rule is tested directly;
    /// ``performLaunchScan()`` applies it once, and only over an empty
    /// selection.
    static func initialSelection(sections: [ProjectSection]) -> Selection? {
        for kind in [ProjectSectionKind.notProtected, .projects] {
            if let first = sections.first(where: { $0.id == kind })?.entries.first {
                return first.id
            }
        }
        return nil
    }

    /// Which projects use shared secret `sharedID`, and under which key.
    ///
    /// Sorted by project, then key, for stable display. Empty for an unused
    /// or unknown ID.
    func usedBy(sharedID: String) -> [(scopeID: String, key: String)] {
        (linkGraph[sharedID] ?? []).sorted {
            $0.scopeID == $1.scopeID ? $0.key < $1.key : $0.scopeID < $1.scopeID
        }
    }

    /// Rescan's status line, in the user's words (Decision 3): "Found 3
    /// projects to protect; 4 already protected." Zero is stated plainly on
    /// both sides rather than as a bare "0".
    static func rescanSummary(toProtect: Int, alreadyProtected: Int) -> String {
        let found: String
        switch toProtect {
        case 0: found = "Found no projects to protect"
        case 1: found = "Found 1 project to protect"
        default: found = "Found \(toProtect) projects to protect"
        }
        let protected = alreadyProtected == 0 ? "none protected yet" : "\(alreadyProtected) already protected"
        return "\(found); \(protected)."
    }

    // MARK: - Action column (Decision 7)

    /// One verb in the action column's selection group (Decision 7), named in
    /// kamae-2.3 §2's ten words.
    ///
    /// The panel renders whatever ``selectionVerbs`` lists, in order; the
    /// title, symbol, and destructive flag travel with the verb so the view
    /// only lays them out and routes the tap.
    enum SelectionVerb: Hashable, Identifiable, CaseIterable {
        /// Protect the selected folder's recommended lines (ho-06.10
        /// Decision 6 — the page is the review; no sheet).
        case protect
        /// Write a project's secrets back into its `.env`.
        case writeEnv
        /// Show what Write .env would put in the file, and where.
        case previewEnv
        /// Open the selected row's folder in Finder.
        case openInFinder
        /// Put a project's secrets back into its `.env` in plain text and
        /// remove it from the vault (destructive; ho-06.10 Decision 8).
        case unprotect
        /// Delete a project and its secrets from the vault (destructive).
        case deleteProject
        /// Protect a Problem folder under the project its claim file names.
        case protectFolder
        /// Remove a Problem folder's claim file (destructive).
        case forgetFolder

        /// Stable identity for `ForEach`.
        var id: Self { self }

        /// The button's always-visible title.
        var title: String {
            switch self {
            case .protect: return "Protect"
            case .writeEnv: return "Write .env"
            case .previewEnv: return "Preview .env"
            case .openInFinder: return "Open in Finder"
            case .unprotect: return "Unprotect"
            case .deleteProject: return "Delete project"
            case .protectFolder: return "Protect this folder"
            case .forgetFolder: return "Forget this folder"
            }
        }

        /// The button's SF Symbol.
        var systemImage: String {
            switch self {
            case .protect, .protectFolder: return "lock.shield"
            case .writeEnv: return "arrow.down.doc"
            case .previewEnv: return "doc.text.magnifyingglass"
            case .openInFinder: return "arrow.up.forward.square"
            case .unprotect: return "lock.open"
            case .deleteProject: return "trash"
            case .forgetFolder: return "minus.circle"
            }
        }

        /// Whether the verb wears pālana rust (`Color.drift`) — the three
        /// that remove something.
        var isDestructive: Bool {
            self == .deleteProject || self == .forgetFolder || self == .unprotect
        }
    }

    /// The disabled reason for a project with no folder on this Mac
    /// (Decision 7): Write .env, Preview .env, and Open in Finder all need one.
    static let noFolderHereReason = "No folder on this Mac — attach one in a later version"

    /// The selection group's verbs, in display order, by the selected row's
    /// kind and status — Decision 7's table.
    ///
    /// Empty when nothing is selected, the selected row has vanished, or a
    /// shared secret is selected (no verbs this ho); the panel omits the
    /// whole group then. A No-folder-here project keeps all four verbs —
    /// three of them disabled by ``writeDisabledReason``.
    var selectionVerbs: [SelectionVerb] {
        guard let entry = selectedEntry else { return [] }
        return entryVerbs(for: entry)
    }

    /// The verbs for `entry`, whether or not it is selected — the action
    /// column's list for the selected row, and the sidebar's right-click menu
    /// for any row (ho-06.10 Decision 8, AT-03).
    func entryVerbs(for entry: ProjectEntry) -> [SelectionVerb] {
        switch entry.id {
        case .candidate:
            return [.protect, .openInFinder]
        case .project:
            return [.writeEnv, .previewEnv, .openInFinder, .unprotect, .deleteProject]
        case .problem:
            guard case .problem(.orphaned) = entry.status else { return [.openInFinder] }
            return [.protectFolder, .forgetFolder, .openInFinder]
        case .shared:
            return []
        }
    }

    /// Why Write .env, Preview .env, and a project's Open in Finder cannot
    /// run, or `nil` when they can.
    ///
    /// Wraps the marker checks ``previewDisabledReason`` and
    /// ``jumpDisabledReason`` make, in the ten words: no project selected;
    /// not scanned yet; or no folder on this Mac (the No-folder-here status,
    /// and any project whose claim file the scan did not find).
    var writeDisabledReason: String? {
        writeDisabledReason(forScope: selectedScopeID)
    }

    /// Why Write .env, Preview .env, and Open in Finder cannot run for the
    /// project `scopeID`, or `nil` when they can — ``writeDisabledReason``
    /// for any row, not only the selected one.
    func writeDisabledReason(forScope scopeID: String?) -> String? {
        guard let scopeID else { return "Select a project first" }
        guard cachedMarker(forScope: scopeID) != nil else {
            return scanReport == nil
                ? "Not scanned yet — rescan to find this project's folder"
                : Self.noFolderHereReason
        }
        return nil
    }

    /// Why `verb` cannot run on the current selection, or `nil` when it can.
    ///
    /// Says nothing about ``activity`` — the panel disables every verb while
    /// one is in flight, on top of this.
    func disabledReason(for verb: SelectionVerb) -> String? {
        disabledReason(for: verb, directory: selectedEntry?.directory, scopeID: selectedScopeID)
    }

    /// Why `verb` cannot run on `entry`, or `nil` when it can.
    ///
    /// The sidebar's right-click menu, for any row (AT-03). Says nothing
    /// about ``activity``, as ``disabledReason(for:)``.
    func disabledReason(for verb: SelectionVerb, on entry: ProjectEntry) -> String? {
        disabledReason(for: verb, directory: entry.directory, scopeID: entry.scopeID)
    }

    /// The one rule behind both disabled-reason reads: the row's folder and
    /// project decide.
    private func disabledReason(for verb: SelectionVerb, directory: URL?, scopeID: String?) -> String? {
        switch verb {
        case .writeEnv, .previewEnv:
            return writeDisabledReason(forScope: scopeID)
        case .openInFinder:
            guard directory == nil else { return nil }
            return writeDisabledReason(forScope: scopeID) ?? Self.noFolderHereReason
        case .unprotect:
            return unprotectDisabledReason(forScope: scopeID)
        case .protect, .deleteProject, .protectFolder, .forgetFolder:
            return nil
        }
    }

    /// The tooltip for `verb`: its disabled reason when it has one, else what
    /// it does, plainly.
    func help(for verb: SelectionVerb) -> String {
        if let reason = disabledReason(for: verb) { return reason }
        switch verb {
        case .protect:
            return "Read this folder's .env and move its secrets into the vault"
        case .writeEnv:
            return "Put this project's secrets back into its .env, touching only its own lines"
        case .previewEnv:
            return "Show exactly what Write .env would put in the file, and where"
        case .openInFinder:
            return "Open this folder in Finder"
        case .unprotect:
            return "Put this project's secrets back into its .env in plain text and remove it from the vault"
        case .deleteProject:
            return "Delete this project and its secrets from the vault — its folder and .env are left in place"
        case .protectFolder:
            return "Bring this folder's .env into the vault as \(selectedEntry?.name ?? "its project")"
        case .forgetFolder:
            return "Remove this folder's claim file — the vault and the .env are untouched"
        }
    }

    /// Whether the drift cache holds an out-of-date project — the gate on
    /// VAULT's Write all out of date (Decision 7). `false` until a Check all
    /// has found something.
    var hasOutOfDateProjects: Bool {
        driftReports.values.contains { Self.isDrifted($0) }
    }

    /// The New… menu's secret item: "Secret in <project>" while a project is
    /// selected (the item's target), else "Secret" (the item is disabled).
    var newSecretMenuTitle: String {
        guard let entry = selectedEntry, entry.scopeID != nil else { return "Secret" }
        return "Secret in \(entry.name)"
    }

    // MARK: - Section rows

    /// Not protected: one row per ``candidates`` folder, in the scanner's
    /// path order, named by the folder.
    private var notProtectedEntries: [ProjectEntry] {
        candidates.map { directory in
            ProjectEntry(
                id: .candidate(directory: directory),
                name: directory.lastPathComponent,
                directory: directory,
                scopeID: nil,
                status: .notProtected
            )
        }
    }

    /// Projects: every vault scope, named by its display name (or ID),
    /// sorted by name; directory from its claim file when one was found.
    private var projectEntries: [ProjectEntry] {
        scopes
            .map { scope in
                ProjectEntry(
                    id: .project(scopeID: scope.identity),
                    name: scope.displayName ?? scope.identity,
                    directory: cachedMarker(forScope: scope.identity)?.markerURL.deletingLastPathComponent(),
                    scopeID: scope.identity,
                    status: projectStatus(forScope: scope.identity)
                )
            }
            .sorted { lhs, rhs in
                let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                return order == .orderedSame ? (lhs.scopeID ?? "") < (rhs.scopeID ?? "") : order == .orderedAscending
            }
    }

    /// Needs attention: one row per ``unlinkedMarkers`` element — named by the
    /// project its claim file names, or "Unreadable claim file" when it will
    /// not load.
    private var needsAttentionEntries: [ProjectEntry] {
        unlinkedMarkers.map { marker in
            let name: String
            switch marker {
            case .orphaned(let scope, _): name = scope
            case .failed: name = "Unreadable claim file"
            }
            return ProjectEntry(
                id: .problem(markerPath: marker.markerPath),
                name: name,
                directory: URL(fileURLWithPath: marker.markerPath).deletingLastPathComponent(),
                scopeID: nil,
                status: .problem(marker)
            )
        }
    }

    /// Shared secrets: one row per ``sharedIDs`` element.
    ///
    /// Status is a placeholder (see ``ProjectEntry/status``).
    private var sharedSecretEntries: [ProjectEntry] {
        sharedIDs.map { sharedID in
            ProjectEntry(
                id: .shared(id: sharedID), name: sharedID, directory: nil, scopeID: nil, status: .protected)
        }
    }
}
