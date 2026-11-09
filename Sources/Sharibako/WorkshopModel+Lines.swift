import Foundation
import SharibakoCore

/// One page per project, protected or not: the project's lines (ho-06.10
/// Decisions 6–7, AT-02).
///
/// A project is a set of `.env` lines, and each line is in the vault or not.
/// ``projectLines`` merges the two keyless reads ``loadContent(for:)`` makes —
/// the vault's keys (``VaultCore/inspect(_:)``) and the folder's `.env`
/// (``Materializer/ingest(directory:)``) — into one list, each line carrying
/// its status, the classifier's recommendation, and the user's choice. A
/// folder the vault does not know yet is the same page with zero protected
/// lines; a project with no folder on this Mac is the same page with no
/// `.env` side. Nothing here decrypts: a protected line carries no value
/// until Reveal (Do Not).
///
/// Everything below except the load is derived on read from ``secrets``,
/// ``WorkshopModel/envRead``, and ``WorkshopModel/lineChoiceFlips``, so a
/// mutation that reloads the secret list (add, delete) refreshes the lines
/// with no second bookkeeping path. The protect intents that commit these
/// lines live in `WorkshopModel+Protect.swift` — the
/// `Conduit`/`Conduit+Remote.swift` split precedent, kept under SwiftLint's
/// `file_length` ceiling.
extension WorkshopModel {
    // MARK: - Types

    /// Where one line stands (Decision 6).
    enum LineStatus: Equatable {
        /// In the vault — a value of its own or a link to a shared secret.
        case protected(kind: SecretInfo.Kind)
        /// In `.env` in plain text, not in the vault, and the classifier
        /// says secret.
        case notProtected
        /// In `.env`, not in the vault, and the classifier says setting.
        case setting
        /// In the vault with no line in the folder's `.env` — only reported
        /// when the project has a folder on this Mac.
        case missingFromEnv

        /// `true` when the vault holds this line: protected, or protected
        /// and missing from `.env`.
        var isInVault: Bool {
            switch self {
            case .protected, .missingFromEnv: return true
            case .notProtected, .setting: return false
            }
        }
    }

    /// What to do with a line not yet in the vault, in plain words
    /// (Decision 7).
    ///
    /// Four choices, not `KeyDecision`'s five: `skip` collapses into
    /// ``leaveAsSetting`` because a user cannot tell them apart, so no
    /// choice ever produces `.skip` (Do Not).
    enum LineChoice: Hashable {
        /// Encrypt the value into this project (`importAsLocal`).
        case protectLocal
        /// Link the line to an existing shared secret (`linkToShared`).
        case useShared(id: String)
        /// Make the value a new shared secret and link it (`moveToShared`).
        case makeShared(id: String)
        /// Leave the line in `.env` as it is (`leaveAlone`).
        case leaveAsSetting

        /// The choice's words, as the page's picker shows them.
        var label: String {
            switch self {
            case .protectLocal: return "Protect for this project"
            case .useShared(let id): return "Use shared secret \(id)"
            case .makeShared: return "Make it a shared secret"
            case .leaveAsSetting: return "Leave in .env as a setting"
            }
        }

        /// `true` for the three choices that put the line in the vault.
        var protects: Bool {
            self != .leaveAsSetting
        }

        /// The engine decision this choice commits for `key`.
        func decision(forKey key: String) -> KeyDecision {
            switch self {
            case .protectLocal: return .importAsLocal(key: key)
            case .useShared(let id): return .linkToShared(key: key, sharedID: id)
            case .makeShared(let id): return .moveToShared(key: key, newSharedID: id)
            case .leaveAsSetting: return .leaveAlone(key: key)
            }
        }
    }

    /// One line of a project's page (Decision 6).
    struct ProjectLine: Identifiable, Equatable {
        /// The line's key — unique within a project, so also its identity.
        var id: String { key }
        /// The `.env` key, or the vault key.
        let key: String
        /// The plaintext value as it stands in `.env`; `nil` for a line in
        /// the vault (never decrypted here) and for one missing from `.env`.
        let value: String?
        /// Where the line stands.
        let status: LineStatus
        /// The classifier's recommendation; `nil` for a line in the vault.
        let lineClass: LineClass?
        /// The recommendation's reason in plain words ("key ends in KEY");
        /// `nil` for a line in the vault.
        let reason: String?
        /// What Protect will do with the line; `nil` for a line in the vault.
        let choice: LineChoice?

        /// The recommendation and its reason as the page's caption shows it —
        /// "secret — key ends in KEY" — or `nil` for a line in the vault.
        var classLabel: String? {
            guard let lineClass, let reason else { return nil }
            return "\(lineClass.isSecret ? "secret" : "setting") — \(reason)"
        }
    }

    /// The page header's state (Decision 6).
    enum ProjectHeaderState: Equatable {
        /// `count` secrets sit in `.env` in plain text.
        case unprotected(count: Int)
        /// Every secret is in the vault. `upToDate` is `nil` until a check
        /// has run, `false` when the last check found `differing` lines.
        ///
        /// The optional Bool is a deliberate tri-state (unchecked, up to
        /// date, differs — the AT-02 spec's shape), hence the SwiftLint
        /// `discouraged_optional_boolean` disable on this line.
        case protected(upToDate: Bool?, differing: Int = 0)  // swiftlint:disable:this discouraged_optional_boolean
        /// The project has no lines at all.
        case empty

        /// The header's words: "3 secrets not protected", "Protected",
        /// "Protected · up to date", "Protected · 2 lines differ", "No lines".
        var label: String {
            switch self {
            case .unprotected(let count):
                return count == 1 ? "1 secret not protected" : "\(count) secrets not protected"
            case .protected(nil, _):
                return "Protected"
            case .protected(true?, _):
                return "Protected · up to date"
            case .protected(false?, let differing):
                return "Protected · " + (differing == 1 ? "1 line differs" : "\(differing) lines differ")
            case .empty:
                return "No lines"
            }
        }

        /// The header's mark: the red octagon while anything is exposed, the
        /// green check once nothing is (the view picks the palette token).
        var symbolName: String {
            switch self {
            case .unprotected: return "xmark.octagon.fill"
            case .protected: return "checkmark.circle.fill"
            case .empty: return "circle.dashed"
            }
        }
    }

    /// A failure from an action taken in the content pane, rendered in that
    /// pane (Decision 8) as well as echoed in the status bar.
    struct PaneError: Equatable {
        /// What went wrong, in plain words.
        let message: String
        /// What the user can do about it, when there is something to say.
        let nextStep: String?
    }

    /// A keyless read of one folder's `.env`-family files.
    struct EnvRead: Equatable, Sendable {
        /// The folder read.
        let directory: URL
        /// Every line with a value, in file order (`.env.local` overriding
        /// `.env`), each carrying its shared-name match and class.
        let lines: [DetectedKey]
        /// Lines the parser could not read, as "<file> line N: <reason>".
        let warnings: [String]
    }

    // MARK: - Derived reads

    /// Every line of the selected page, secrets first (Decision 6).
    ///
    /// Secrets — protected, not protected, missing from `.env` — in file
    /// order, then the vault's remaining keys in vault order; then the
    /// settings. Derived on read; see the file header.
    var projectLines: [ProjectLine] {
        Self.deriveLines(vault: cachedSecrets, env: envRead, flips: lineChoiceFlips)
    }

    /// The secret lines — everything but the settings — for the page's list.
    var secretLines: [ProjectLine] {
        projectLines.filter { $0.status != .setting }
    }

    /// The setting lines, for the page's fold ("7 settings left in .env").
    var settingLines: [ProjectLine] {
        projectLines.filter { $0.status == .setting }
    }

    /// How many secrets sit in `.env` in plain text — the header's count.
    var unprotectedSecretCount: Int {
        projectLines.filter { $0.status == .notProtected }.count
    }

    /// How many lines Protect would put in the vault with the current
    /// choices — the count on the page's Protect button.
    ///
    /// Differs from ``unprotectedSecretCount`` when the user has flipped a
    /// line: a secret left as a setting still counts as unprotected in the
    /// header (it *is* in plain text) but is not protected by the button.
    var protectableLineCount: Int {
        projectLines.filter { $0.choice?.protects == true }.count
    }

    /// `true` while the selection is a folder the vault does not know yet.
    var isCandidate: Bool {
        if case .candidate = selection { return true }
        return false
    }

    /// The line behind ``WorkshopModel/selectedLineKey``, or `nil`.
    var selectedLine: ProjectLine? {
        guard let key = selectedLineKey else { return nil }
        return projectLines.first { $0.key == key }
    }

    /// The parse warnings from the page's `.env` read.
    var lineWarnings: [String] {
        envRead?.warnings ?? []
    }

    /// The page header's state (Decision 6).
    ///
    /// Unprotected while any secret sits in `.env` in plain text; else no
    /// lines at all is ``ProjectHeaderState/empty``; else protected, with
    /// the up-to-date clause from the last check when one has run for the
    /// selected project (never for a folder the vault does not know).
    var headerState: ProjectHeaderState {
        let lines = projectLines
        let exposed = lines.filter { $0.status == .notProtected }.count
        if exposed > 0 { return .unprotected(count: exposed) }
        if lines.isEmpty { return .empty }
        guard let scopeID = selectedScopeID, let report = driftReports[scopeID] else {
            return .protected(upToDate: nil)
        }
        let differing = Self.driftedKeyCount(report)
        return .protected(upToDate: differing == 0, differing: differing)
    }

    // MARK: - Derivation (pure)

    /// Merges a vault key list and a `.env` read into page lines.
    ///
    /// Static and pure so every status and ordering rule is tested directly.
    /// A key in both is ``LineStatus/protected(kind:)`` with no value; a
    /// `.env` line not in the vault takes its status from the classifier; a
    /// vault key with no `.env` line is ``LineStatus/missingFromEnv`` when
    /// there is a `.env` side at all, else plain protected.
    static func deriveLines(
        vault: [SecretInfo], env: EnvRead?, flips: [String: LineChoice]
    ) -> [ProjectLine] {
        var kinds: [String: SecretInfo.Kind] = [:]
        for info in vault where kinds[info.key] == nil {
            kinds[info.key] = info.kind
        }
        var secrets: [ProjectLine] = []
        var settings: [ProjectLine] = []
        var seen = Set<String>()
        for detected in env?.lines ?? [] {
            guard seen.insert(detected.key).inserted else { continue }
            if let kind = kinds[detected.key] {
                secrets.append(Self.vaultLine(key: detected.key, status: .protected(kind: kind)))
                continue
            }
            let lineClass = detected.lineClass
            let flip = env.flatMap { flips[lineChoiceKey(folder: $0.directory, key: detected.key)] }
            let line = ProjectLine(
                key: detected.key,
                value: detected.value,
                status: lineClass.isSecret ? .notProtected : .setting,
                lineClass: lineClass,
                reason: lineClass.reason.explanation,
                choice: flip ?? defaultChoice(for: detected)
            )
            if lineClass.isSecret {
                secrets.append(line)
            } else {
                settings.append(line)
            }
        }
        for info in vault {
            guard seen.insert(info.key).inserted else { continue }
            let status: LineStatus = env == nil ? .protected(kind: info.kind) : .missingFromEnv
            secrets.append(Self.vaultLine(key: info.key, status: status))
        }
        return secrets + settings
    }

    /// The classifier's default choice for a `.env` line (Decision 7): a
    /// secret is protected for this project, or linked to the shared secret
    /// its name matches; a setting is left in `.env`.
    static func defaultChoice(for detected: DetectedKey) -> LineChoice {
        guard detected.lineClass.isSecret else { return .leaveAsSetting }
        if let shared = detected.nameMatchedSharedID { return .useShared(id: shared) }
        return .protectLocal
    }

    /// The ``WorkshopModel/lineChoiceFlips`` key for `key` in `folder`: the
    /// standardized folder path and the key, joined by a newline (which no
    /// `.env` key or path component the scan produces can contain).
    static func lineChoiceKey(folder: URL, key: String) -> String {
        "\(folder.standardizedFileURL.path)\n\(key)"
    }

    /// A line the vault holds: no value, no class, no choice.
    private static func vaultLine(key: String, status: LineStatus) -> ProjectLine {
        ProjectLine(key: key, value: nil, status: status, lineClass: nil, reason: nil, choice: nil)
    }

    // MARK: - Scope ID for a new project

    /// The project ID a folder protects under (Decision 6): its name,
    /// lowercased, every character outside the vault's identifier grammar
    /// turned into `-` (runs collapsed, ends trimmed), then `-2`, `-3`, … on
    /// a collision with `existing`.
    ///
    /// Validated by ``VaultCore/isValidIdentifier(_:)``; a name with nothing
    /// usable left falls back to `project`. Never prompts (Do Not).
    static func suggestedScopeID(for directory: URL, existing: Set<String>) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._-")
        var mapped = ""
        for char in directory.lastPathComponent.lowercased() {
            let next: Character = allowed.contains(char) ? char : "-"
            if next == "-", mapped.hasSuffix("-") { continue }
            mapped.append(next)
        }
        let trimmed = mapped.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        let base = VaultCore.isValidIdentifier(trimmed) ? trimmed : "project"
        guard existing.contains(base) else { return base }
        var suffix = 2
        while existing.contains("\(base)-\(suffix)") {
            suffix += 1
        }
        return "\(base)-\(suffix)"
    }

    // MARK: - Choice

    /// Sets one line's choice on the selected page (Decision 7).
    ///
    /// Remembered for the session in ``WorkshopModel/lineChoiceFlips``.
    /// A no-op for a line in the vault (it has no choice), for a page with no
    /// `.env` read, for ``LineChoice/useShared(id:)`` naming a shared secret
    /// the vault does not have, and for ``LineChoice/makeShared(id:)`` with
    /// an ID outside the identifier grammar or one already taken — each of
    /// those would only fail at Protect. Choosing the default again drops
    /// the flip rather than storing it.
    func setLineChoice(_ choice: LineChoice, forKey key: String) {
        guard let env = envRead,
            let detected = env.lines.first(where: { $0.key == key }),
            !cachedSecrets.contains(where: { $0.key == key })
        else { return }
        switch choice {
        case .useShared(let id):
            guard sharedIDs.contains(id) else { return }
        case .makeShared(let id):
            guard VaultCore.isValidIdentifier(id), !sharedIDs.contains(id) else { return }
        case .protectLocal, .leaveAsSetting:
            break
        }
        let flipKey = Self.lineChoiceKey(folder: env.directory, key: key)
        lineChoiceFlips[flipKey] = choice == Self.defaultChoice(for: detected) ? nil : choice
    }

    /// Forgets every flip for `folder` — run once it has been protected.
    func clearLineChoices(for folder: URL) {
        let prefix = Self.lineChoiceKey(folder: folder, key: "")
        lineChoiceFlips = lineChoiceFlips.filter { !$0.key.hasPrefix(prefix) }
    }

    // MARK: - Load

    /// Loads what the content column needs for `selection`: the lines of a
    /// project, a folder not yet protected, or a Problem folder whose claim
    /// file names a project (ho-06.10 AT-02).
    ///
    /// Two keyless worker hops: ``VaultCore/inspect(_:)`` for a project's
    /// vault keys, then ``Materializer/ingest(directory:)`` for the folder's
    /// `.env` when there is a folder. They fail apart — an unreadable `.env`
    /// still shows the vault's keys — and both failures land in the page's
    /// pane (while it is still selected) and ``errorMessage`` (ho-06.10
    /// AT-04). Results land only while `selection` is still selected
    /// (``storeLinesRead(secrets:env:for:)``). Not gated on ``activity``:
    /// it is a quick read the page fires on selection, the serial ``worker``
    /// already orders it after any scan, and the protect intents call it
    /// mid-activity to refresh the page they just committed. Shared and
    /// unreadable-claim-file pages load nothing. Fired by the content
    /// column's `.task(id:)`, which re-runs on every selection change.
    func loadContent(for selection: Selection?) async {
        guard case .open(let vaultURL) = vaultState, let selection else { return }
        let scopeID: String?
        let folder: URL?
        switch selection {
        case .project(let id):
            guard VaultCore.isValidIdentifier(id) else { return }
            scopeID = id
            folder = cachedMarker(forScope: id)?.markerURL.deletingLastPathComponent()
        case .candidate(let directory):
            scopeID = nil
            folder = directory
        case .problem(let markerPath):
            scopeID = nil
            folder = orphanedClaim(markerPath: markerPath)?.folder
        case .shared:
            return
        }
        var secrets: [SecretInfo] = []
        if let scopeID {
            do {
                secrets = try await worker.run { try VaultCore(vaultURL: vaultURL).inspect(scopeID) }
                errorMessage = nil
            } catch {
                reportReadFailure(error, for: selection)
            }
        }
        var env: EnvRead?
        if let folder {
            do {
                env = try await worker.run { try EnvReader.read(directory: folder, vaultURL: vaultURL) }
                if scopeID == nil { errorMessage = nil }
            } catch {
                reportReadFailure(error, for: selection)
            }
        }
        storeLinesRead(secrets: secrets, env: env, for: selection)
    }

    /// Reports a failed page read: in the page's pane while `selection` is
    /// still the selection, else only in the status bar — a read that
    /// finishes after the user moved on must not land on another page.
    private func reportReadFailure(_ error: Error, for selection: Selection) {
        if self.selection == selection {
            reportPaneError(for: error)
        } else {
            errorMessage = Self.message(for: error)
        }
    }

    /// The project name and folder behind a Needs-attention row whose claim
    /// file names a project the vault does not have, or `nil` for any other
    /// path (an unreadable claim file, or a row that has gone).
    func orphanedClaim(markerPath: String) -> (scope: String, folder: URL)? {
        for marker in unlinkedMarkers {
            if case .orphaned(let scope, let markerURL) = marker, markerURL.path == markerPath {
                return (scope, markerURL.deletingLastPathComponent())
            }
        }
        return nil
    }
}

// MARK: - Reading a folder (pure, off-main-actor-safe)

/// The keyless `.env` read behind a page's lines and every Protect.
///
/// A plain `enum` (never instantiated), not a `WorkshopModel` static method:
/// it runs inside `VaultWorker.run`'s `@Sendable` closure, off the main
/// actor, and a method on the `@MainActor` model would carry that isolation
/// into the closure.
enum EnvReader {
    /// Reads a folder's `.env` files, parsing only.
    ///
    /// Through ``Materializer/ingest(directory:)``; nothing is decrypted.
    static func read(directory: URL, vaultURL: URL) throws -> WorkshopModel.EnvRead {
        let core = try VaultCore(vaultURL: vaultURL)
        let proposal = try Materializer(vaultCore: core, vaultURL: vaultURL).ingest(directory: directory)
        let warnings = proposal.parseWarnings.map {
            "\($0.file.lastPathComponent) line \($0.lineNumber): \($0.reason)"
        }
        return WorkshopModel.EnvRead(directory: directory, lines: proposal.detectedKeys, warnings: warnings)
    }
}
