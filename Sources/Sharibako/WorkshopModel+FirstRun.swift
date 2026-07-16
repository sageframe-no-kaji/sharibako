import Foundation
import SharibakoCore

/// The first-run wizard's state machine and intents (ho-06.3 Decisions 1, 2,
/// 4, 5, 8) — the Workshop's front door when ``WorkshopModel/vaultState`` is
/// `.noVault`. `FirstRunWizard` (`Views/FirstRunWizard.swift`) reads
/// ``WorkshopModel/firstRun`` and calls the intents below; no branching logic
/// lives in the view (Required Change 4, Do Not §5).
///
/// Split out of `WorkshopModel.swift` the way every other feature's intents
/// are (`WorkshopModel+Mutations.swift`, `+Heal.swift`, `+Waymarking.swift`)
/// — the `Conduit`/`Conduit+Remote.swift` precedent. `FirstRunState` is a
/// nested `@Observable` type declared here rather than more stored properties
/// on `WorkshopModel` itself (see `WorkshopModel.swift`'s ``WorkshopModel/firstRun``
/// doc); `WorkshopModel.swift` only had to add that one property plus the
/// `bindOpenedVault(at:)` seam this file's ``completeFirstRun()`` calls.
extension WorkshopModel {
    // MARK: - Nested state

    /// The wizard's ordered pages (Decision 1).
    enum FirstRunPage: Int, CaseIterable, Equatable, Sendable {
        case prereq
        case key
        case backup
        case root
        case remote
        case finish
    }

    /// How the key page resolved (Decision 1 step 2).
    enum FirstRunKeyMode: Equatable, Sendable {
        /// No key decision made yet.
        case notChosen
        /// A Keychain key already existed — nothing to generate (never a
        /// second key).
        case existingKeyFound
        /// A fresh key was generated into the Keychain this session.
        case generated
        /// An existing identity file was imported into the Keychain.
        case imported
    }

    /// A freshly generated identity awaiting a verified backup (Decision 2).
    ///
    /// Held only for the backup page's lifetime — ``advanceFromBackup()``
    /// clears it once the saved file verifies.
    struct FirstRunPendingBackup: Equatable {
        /// The full identity file contents, written verbatim to the backup file.
        let identity: String
        /// The `age1…` recipient, shown for reference.
        let recipient: String
    }

    /// The first-run wizard's own observable state.
    ///
    /// `@Observable` so `FirstRunWizard` re-renders on every field it reads,
    /// the same tracking `WorkshopModel` itself relies on. `@MainActor` for
    /// the same reason the owning `WorkshopModel` is — every mutator below is
    /// a `WorkshopModel` intent, always called from the main actor.
    @Observable
    @MainActor
    final class FirstRunState {
        // Every field below is `internal var`, not `private(set)`: the
        // mutating intents live in `extension WorkshopModel` — a different
        // TYPE from `FirstRunState`, even though declared in this same file.
        // Swift's `private`/`private(set)` extends across same-file
        // extensions of the SAME type only, not across types — the identical
        // reason `WorkshopModel`'s own `pendingScopeDeletion`/`allStalePlan`/
        // `envPreview` are plain `var`. Views only ever read these; the
        // intents below are the only writers by convention, not by the
        // compiler.

        /// The current page.
        var page: FirstRunPage = .prereq

        /// Whether the last prereq check found both `age` and `age-keygen`.
        var prerequisitesOK = false

        /// How the key page resolved.
        var keyMode: FirstRunKeyMode = .notChosen

        /// The freshly generated identity awaiting a verified backup, or
        /// `nil` on the import path (Decision 2 skips the backup page) or
        /// before generation runs.
        var pendingBackup: FirstRunPendingBackup?

        /// Whether ``WorkshopModel/verifyFirstRunBackup(at:)`` last found the
        /// saved file's contents matching the pending identity exactly —
        /// gates the backup page's Continue (Decision 2: the wizard *knows*
        /// the backup happened, never a trusted checkbox).
        var backupVerified = false

        /// The detected/suggested scan root (Decision 4), or `nil` before
        /// ``WorkshopModel/suggestFirstRunScanRoot(home:)`` has run or found
        /// nothing plausible.
        var scanRoot: URL?

        /// The optional remote URL text (Decision 1 step 5); empty means skip.
        var remoteURLText = ""

        /// Set when ``WorkshopModel/completeFirstRun()`` accepts everything
        /// but the remote URL, so the finish page can surface the rejection
        /// inline without aborting vault creation (Decision 1 step 6).
        var remoteURLError: String?

        /// Human-facing failure from the last intent that can fail, or `nil`.
        var errorMessage: String?

        init() {}
    }

    /// The Keychain write/probe seam threaded through the key page's intents
    /// — production defaults to `GUIKeychainAgeKeyProvider()`; tests inject a
    /// fake so nothing here ever touches the real Keychain (Do Not §4).
    static func productionKeychainStore() -> GUIKeychainStore {
        GUIKeychainAgeKeyProvider()
    }

    // MARK: - Prereq page (Decision 1 step 1)

    /// Re-checks for `age`/`age-keygen` and updates the prereq state in ``firstRun``.
    ///
    /// Called by the page's own appearance and its Re-check button alike.
    ///
    /// - Parameter probe: Defaults to `GUIAgeKeyBootstrap.prerequisitesPresent`;
    ///   tests inject `{ false }` (or similar) to exercise the blocked state
    ///   without hiding real binaries from `PATH`.
    func checkFirstRunPrerequisites(
        probe: () -> Bool = GUIAgeKeyBootstrap.prerequisitesPresent
    ) {
        firstRun.prerequisitesOK = probe()
    }

    /// Advances past the prereq page once ``checkFirstRunPrerequisites()``
    /// found both binaries; a no-op otherwise (the view already disables
    /// Continue — this is the defensive guard).
    func advanceFromPrereq() {
        guard firstRun.prerequisitesOK else { return }
        firstRun.page = .key
    }

    // MARK: - Key page (Decision 1 step 2)

    /// Checks whether a Sharibako Keychain key already exists and updates
    /// the key mode in ``firstRun``.
    ///
    /// Called when the key page appears.
    ///
    /// - Parameter store: The Keychain probe seam (see ``productionKeychainStore()``).
    func checkExistingKeychainKey(store: GUIKeychainStore = productionKeychainStore()) {
        do {
            if try GUIAgeKeyBootstrap.keychainKeyExists(store: store) {
                firstRun.keyMode = .existingKeyFound
            }
            firstRun.errorMessage = nil
        } catch {
            firstRun.errorMessage = Self.message(for: error)
        }
    }

    /// Generates a fresh key into the Keychain and stages the backup page
    /// (Decision 1 step 2, Decision 2).
    ///
    /// A no-op when a key already exists (``FirstRunKeyMode/existingKeyFound``)
    /// — the view's button is disabled in that state; this is the defensive
    /// guard (never a second key).
    ///
    /// - Parameter store: The Keychain write seam (see ``productionKeychainStore()``).
    func generateFirstRunKey(store: GUIKeychainStore = productionKeychainStore()) {
        guard firstRun.keyMode != .existingKeyFound else { return }
        do {
            let (identity, recipient) = try GUIAgeKeyBootstrap.generateToKeychain(store: store)
            firstRun.keyMode = .generated
            firstRun.pendingBackup = FirstRunPendingBackup(identity: identity, recipient: recipient)
            firstRun.errorMessage = nil
            firstRun.page = .backup
        } catch {
            firstRun.errorMessage = Self.message(for: error)
        }
    }

    /// Validates and imports an existing identity file, then skips straight
    /// to the root page (Decision 1 step 2; Decision 2 — import needs no
    /// backup nudge, the file already lives outside the Keychain).
    ///
    /// A no-op when a key already exists, the same guard as
    /// ``generateFirstRunKey(store:)``.
    ///
    /// - Parameters:
    ///   - url: The identity file the user picked.
    ///   - store: The Keychain write seam (see ``productionKeychainStore()``).
    func importFirstRunKey(from url: URL, store: GUIKeychainStore = productionKeychainStore()) {
        guard firstRun.keyMode != .existingKeyFound else { return }
        do {
            _ = try GUIAgeKeyBootstrap.importToKeychain(from: url, store: store)
            firstRun.keyMode = .imported
            firstRun.errorMessage = nil
            firstRun.page = .root
        } catch {
            firstRun.errorMessage = Self.message(for: error)
        }
    }

    /// Advances from the key page — reachable only in the
    /// ``FirstRunKeyMode/existingKeyFound`` state; generate and import both
    /// advance the page themselves the moment they succeed.
    func advanceFromKeyPage() {
        guard firstRun.keyMode == .existingKeyFound else { return }
        firstRun.page = .root
    }

    // MARK: - Backup page (Decision 2)

    /// Re-reads the file at `url` and marks the backup verified only when its
    /// contents match ``FirstRunState/pendingBackup`` exactly — Continue
    /// enables from this, never a trusted checkbox.
    func verifyFirstRunBackup(at url: URL) {
        guard let pending = firstRun.pendingBackup,
            let saved = try? String(contentsOf: url, encoding: .utf8)
        else {
            firstRun.backupVerified = false
            return
        }
        firstRun.backupVerified = saved == pending.identity
    }

    /// Advances from the backup page once verified, clearing the in-memory
    /// identity (Decision 2 — held only as long as this page needs it).
    func advanceFromBackup() {
        guard firstRun.backupVerified else { return }
        firstRun.pendingBackup = nil
        firstRun.backupVerified = false
        firstRun.page = .root
    }

    // MARK: - Root page (Decision 4)

    /// Candidate directories probed under `home`, in preference order.
    static let firstRunRootCandidates = ["Projects", "Developer", "Code", "Vaults", "src", "dev"]

    /// Suggests an initial scan root: the first *existing* candidate under
    /// `home`, tie-broken toward whichever holds git repositories one level
    /// down — pure logic over an injected `home` (Decision 4).
    ///
    /// Sets ``FirstRunState/scanRoot`` to `nil` when no candidate exists (the
    /// view then requires an explicit folder choice).
    func suggestFirstRunScanRoot(home: URL) {
        let fileManager = FileManager.default
        let existing = Self.firstRunRootCandidates
            .map { home.appendingPathComponent($0) }
            .filter { url in
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
        guard !existing.isEmpty else {
            firstRun.scanRoot = nil
            return
        }
        // `max(by:)` keeps the FIRST element on a tie (Swift's documented
        // behavior for equally-maximal elements), so candidates with equal
        // git-repo counts fall back to `firstRunRootCandidates`' own
        // preference order rather than an arbitrary pick.
        firstRun.scanRoot = existing.max { lhs, rhs in
            Self.shallowGitRepoCount(in: lhs) < Self.shallowGitRepoCount(in: rhs)
        }
    }

    /// A shallow (one-level) count of immediate subdirectories containing
    /// `.git` — the root suggestion's tie-break signal (Decision 4).
    ///
    /// Not a deep walk: the suggestion only needs "some git activity here",
    /// and a wide root must resolve fast (the ho's candidate-scan-depth
    /// Discovery).
    private static func shallowGitRepoCount(in directory: URL) -> Int {
        let fileManager = FileManager.default
        guard
            let children = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
        else {
            return 0
        }
        return children.filter { child in
            fileManager.fileExists(atPath: child.appendingPathComponent(".git").path)
        }.count
    }

    /// Accepts a folder-picker override for the scan root (Decision 4's
    /// "usually right, not guaranteed" escape hatch).
    func setFirstRunScanRootOverride(_ url: URL) {
        firstRun.scanRoot = url
    }

    /// Advances from the root page.
    ///
    /// A root is optional in the type system but required to advance —
    /// ``suggestFirstRunScanRoot(home:)`` can come back empty on an unusual
    /// machine, and the wizard needs *some* root to reach ``completeFirstRun()``.
    func advanceFromRoot() {
        guard firstRun.scanRoot != nil else { return }
        firstRun.page = .remote
    }

    // MARK: - Remote page (Decision 1 step 5)

    /// Records the optional remote URL text; empty means skip.
    ///
    /// Clears any prior rejection so a corrected retry doesn't carry a stale
    /// error.
    func setFirstRunRemoteURL(_ text: String) {
        firstRun.remoteURLText = text
        firstRun.remoteURLError = nil
    }

    /// Advances from the remote page — always allowed, the field is optional.
    func advanceFromRemote() {
        firstRun.page = .finish
    }

    // MARK: - Page navigation

    /// Advances from the current page using that page's own guard — the
    /// wizard's single Continue entry point, so the view never switches on
    /// ``FirstRunState/page`` to decide which intent to call.
    func advanceFirstRunPage() {
        switch firstRun.page {
        case .prereq: advanceFromPrereq()
        case .key: advanceFromKeyPage()
        case .backup: advanceFromBackup()
        case .root: advanceFromRoot()
        case .remote: advanceFromRemote()
        case .finish: break
        }
    }

    /// `true` when the current page's Continue button should enable —
    /// mirrors each page's own advance guard so the view never duplicates
    /// the state machine's conditions (the `jumpDisabledReason`/
    /// `previewDisabledReason` precedent, `WorkshopModel+Waymarking.swift` /
    /// `WorkshopModel+Preview.swift`).
    var firstRunCanContinue: Bool {
        switch firstRun.page {
        case .prereq: return firstRun.prerequisitesOK
        case .key: return firstRun.keyMode == .existingKeyFound
        case .backup: return firstRun.backupVerified
        case .root: return firstRun.scanRoot != nil
        case .remote: return true
        case .finish: return false
        }
    }

    /// Steps back one page. `.prereq` has no previous page.
    ///
    /// Stepping back from `.root` lands on `.key` for the import path (which
    /// skipped `.backup` going forward) and on `.backup` for the generate
    /// path — the backward step mirrors whichever forward step actually ran,
    /// rather than a fixed `page - 1`.
    func goToPreviousFirstRunPage() {
        switch firstRun.page {
        case .prereq:
            return
        case .key:
            firstRun.page = .prereq
        case .backup:
            firstRun.page = .key
        case .root:
            firstRun.page = firstRun.keyMode == .imported ? .key : .backup
        case .remote:
            firstRun.page = .root
        case .finish:
            firstRun.page = .remote
        }
    }

    // MARK: - Finish (Decision 1 step 6, Decision 8)

    /// Creates the vault, git-inits it, and flips the model to `.open`.
    ///
    /// Falls back to a local git identity when none is configured (Decision
    /// 8), sets the optional remote (surfacing a rejection inline rather
    /// than aborting), persists the scan root, flips
    /// ``WorkshopModel/vaultState`` to `.open`, and warms the scope list +
    /// launch-scan cache (ho-06.1). Announces the outcome (the
    /// silent-success rule) and sets ``WorkshopModel/firstRunCompleted`` —
    /// the seam AT-02 consumes for the ingest invite (left unbuilt here, Do
    /// Not §6).
    ///
    /// A no-op outside `.noVault` or without a resolved scan root — the view
    /// keeps "Create Vault" disabled until both hold; this is the defensive
    /// guard. Guards re-entry against ``WorkshopModel/activity`` like every
    /// other long intent, even though the work here is fast local git/file
    /// I/O rather than worker-routed tree-walking.
    func completeFirstRun() async {
        guard activity == nil else { return }
        guard case .noVault(let expectedPath) = vaultState else { return }
        guard let scanRoot = firstRun.scanRoot else { return }
        do {
            try VaultCore.createVault(at: expectedPath)
            let conduit = try Conduit(vaultURL: expectedPath)
            try conduit.initializeRepository()
            try ensureFirstRunGitIdentity(conduit: conduit, vaultURL: expectedPath)
            try setFirstRunRemoteIfProvided(conduit: conduit)

            try WorkshopConfig.persistScanRoot(scanRoot, configURL: configURL)
            scanRoots = WorkshopConfig.loadScanRoots(configURL: configURL)

            bindOpenedVault(at: expectedPath)
            loadScopes()
            statusMessage = "Created vault at \(expectedPath.path)."
            errorMessage = nil
            firstRunCompleted = true
            await performLaunchScan()
        } catch {
            firstRun.errorMessage = Self.message(for: error)
        }
    }

    /// Resolves whether the vault's git identity is configured; sets a local
    /// fallback identity when it is not (Decision 8 — a non-expert's first
    /// sync must not die on a missing `user.email`).
    ///
    /// Shells `git -C <vault> config user.email` directly through
    /// ``GUIShell`` — a light, fast local read with no CLI precedent to
    /// mirror (this ho's own Discovery: git-identity detection is an
    /// implementation find inside the existing `Conduit` surface, not a new
    /// Core API). The unscoped `git config` lookup checks local-then-global —
    /// intentionally: Decision 8 only wants the fallback when NO identity
    /// exists anywhere, not when the machine already has a perfectly good
    /// global one. That makes the read sensitive to `HOME` (where global
    /// `~/.gitconfig` lives), so it runs with
    /// ``WorkshopModel/processEnvironment`` as `GUIShell.run`'s
    /// `environmentOverrides` — production sees the real environment
    /// unchanged; tests inject a `HOME` with no gitconfig to exercise the
    /// fallback deterministically, without touching the real developer
    /// machine's own git identity.
    private func ensureFirstRunGitIdentity(conduit: Conduit, vaultURL: URL) throws {
        let git = try GUIShell.findExecutable("git")
        let result = try GUIShell.run(
            git,
            ["-C", vaultURL.path, "config", "user.email"],
            environmentOverrides: processEnvironment
        )
        let email = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode != 0 || email.isEmpty else { return }
        try conduit.setIdentity(name: "Sharibako", email: "sharibako@localhost")
    }

    /// Sets the optional remote when the wizard's remote page carries text.
    ///
    /// A `VaultError.remoteURLRejected` is caught and surfaced on
    /// ``FirstRunState/remoteURLError`` rather than rethrown — the vault
    /// still gets created; only the remote step is skipped (Acceptance: "a
    /// rejected remote URL surfaces inline and does not abort the vault").
    /// Any other error propagates, since those indicate a real git failure,
    /// not a user-input problem.
    private func setFirstRunRemoteIfProvided(conduit: Conduit) throws {
        let remoteText = firstRun.remoteURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remoteText.isEmpty else { return }
        do {
            try conduit.setRemote(remoteText)
        } catch let error as VaultError {
            guard case .remoteURLRejected(_, let reason) = error else { throw error }
            firstRun.remoteURLError = "Remote rejected: \(reason)"
        }
    }
}
