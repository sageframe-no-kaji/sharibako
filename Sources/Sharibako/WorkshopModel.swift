import Foundation
import Observation
import SharibakoCore

/// The Workshop's root observable model (ho-05 Decision 2).
///
/// One instance is constructed at app launch and injected via `.environment`.
/// It owns the resolved configuration and constructs `SharibakoCore` types per
/// operation; views read published state and call intent methods — no view
/// touches vault logic directly beyond displaying results.
///
/// Fast single-file operations (reveal, add, rotate, notes) run synchronously
/// on the main actor. The long operations — `rescan`, `materializeSelectedScope`,
/// `sync` — are `async` intents (ho-06.1 Decision 1, amending ho-05 Decision 2's
/// synchronous posture for tree-walking and network work): they set ``activity``,
/// hand the blocking Core work to ``worker`` (a ``VaultWorker`` actor), and
/// publish results back here on the main actor. The model stays
/// `@Observable @MainActor` and owns all published state; only the blocking work
/// hops off-main.
@Observable
@MainActor
final class WorkshopModel {
    /// A long-running vault operation currently in flight, or `nil` when idle.
    ///
    /// Non-nil ``activity`` drives the responsiveness UI (ho-06.1 Decision 1):
    /// the toolbar's vault-action buttons disable and the status surface shows
    /// a progress indicator with ``Activity/label``. The async intents guard
    /// re-entry against it — an intent called while it is non-nil returns
    /// without work — so the UI stays honest even though ``worker`` already
    /// serializes execution.
    enum Activity: Equatable {
        /// A scan (launch scan or Rescan) is walking the scan roots.
        case scanning
        /// A materialize is decrypting and writing a scope's `.env` target.
        case materializing
        /// A sync is committing and pushing to the remote.
        case syncing
        /// A Check-drift sweep is decrypting and comparing every `live_here`
        /// scope against its materialized `.env` (ho-06.2 AT-02, Decision 3).
        case checkingDrift

        /// Progress text shown beside the indicator in the status surface.
        var label: String {
            switch self {
            case .scanning: return "Scanning…"
            case .materializing: return "Materializing…"
            case .syncing: return "Syncing…"
            case .checkingDrift: return "Checking drift…"
            }
        }
    }

    /// The long-running operation in flight, or `nil` when idle.
    ///
    /// `internal` (not `private(set)`): ``previewEnv()``
    /// (`WorkshopModel+Preview.swift`, AT-03) is a long operation of its own
    /// — it decrypts every scope secret through ``worker``, the same weight
    /// as materialize — and sets this the same way every other async intent
    /// does. Cross-file-extension access follows the `Conduit`/
    /// `Conduit+Remote.swift` precedent; views still only ever read it.
    var activity: Activity?

    /// Serial off-main execution domain for blocking Core work (Decision 1).
    ///
    /// One instance per model. Every long operation's tree-walk / shell-out
    /// runs through it, so two operations submitted here cannot interleave.
    let worker = VaultWorker()

    /// The latest scan report, held in memory for the session (Decision 2).
    ///
    /// Populated by ``performLaunchScan()`` at window open and refreshed by
    /// ``rescan(openPanel:)``. ``materializeSelectedScope(force:)`` resolves its
    /// marker from here instead of re-walking the scan root per action, and
    /// AT-02's jump-to-directory button plus ho-06.2's glyphs read it through
    /// ``cachedMarker(forScope:)``. Never persisted — markers change externally,
    /// and a persisted cache would lie across sessions.
    private(set) var scanReport: ScanReport?

    /// Per-scope drift, pulled on demand and cached for the session (ho-06.2
    /// AT-02, Decision 3).
    ///
    /// Keyed by scope id. Populated ONLY by an explicit ``checkDrift()`` sweep
    /// — never at launch, never on selection — because ``Materializer/heal(marker:)``
    /// decrypts every owned key, so a drift check costs the age key and a Touch
    /// ID; rendering badges ambiently would prompt Touch ID the moment the
    /// window opens, undoing ho-06.1's "window interactive immediately"
    /// achievement. Never persisted (markers and files change externally; a
    /// persisted drift cache would lie across sessions) — same posture as
    /// ``scanReport``. A scope's entry is cleared when it reconciles so the
    /// badge stops showing stale drift. `internal` (not `private(set)`, unlike
    /// ``scanReport``): the sweep, the classification helpers, and the
    /// reconcile refresh all live in `WorkshopModel+Heal.swift`, and Swift's
    /// `private(set)` is file-scoped — a same-module extension file cannot
    /// write it (the same reason ``statusMessage`` and ``envPreview`` are
    /// plain `var`; the `Conduit`/`Conduit+Remote.swift` precedent). Views only
    /// ever read it.
    var driftReports: [String: DriftReport] = [:]

    /// The vault's git remote, resolved once at launch (AT-02 Decision 3).
    ///
    /// `nil` while unresolved (the sidebar footer omits the remote line until
    /// this is set, rather than guessing "no remote" before the fast local
    /// git call returns). Resolved alongside ``performLaunchScan()`` — not
    /// per-render — via ``Conduit/remoteURL()``. A vault with no `.git/` or no
    /// configured `origin` resolves to ``RemoteDescription/none``, which the
    /// footer states plainly rather than treating as an error.
    private(set) var remoteDescription: RemoteDescription?

    /// The vault's git remote, as read at launch.
    enum RemoteDescription: Equatable {
        /// `origin` is configured; carries the full URL string.
        case configured(url: String)
        /// The vault has no configured `origin` (or no `.git/` at all).
        case none
    }

    /// Whether the resolved vault path holds an openable vault.
    enum VaultState: Equatable {
        /// No vault at the resolved path; the window shows the empty state
        /// naming `expectedPath` — never silent creation (Decision 3).
        case noVault(expectedPath: URL)
        /// An existing vault the Workshop has bound to.
        case open(vaultURL: URL)
    }

    /// The resolved vault binding, fixed at init for v1 (re-resolution is ho-06).
    private(set) var vaultState: VaultState

    /// Every scope in the open vault, sorted by identity (as `listScopes` returns).
    private(set) var scopes: [ScopeMetadata] = []

    /// Identity of the sidebar-selected scope, if any.
    ///
    /// Setting this clears ``selectedSecretKey`` and ``revealedValue`` —
    /// changing scope re-masks any revealed value (Decision 4).
    var selectedScopeID: String? {
        didSet {
            if selectedScopeID != oldValue {
                selectedSecretKey = nil
                revealedValue = nil
                revealedNotes = nil
                cachedSecrets = []
                cachedHistory = []
            }
        }
    }

    /// Secrets in the selected scope, populated by ``loadSecrets()``.
    private(set) var cachedSecrets: [SecretInfo] = []

    /// The key of the currently selected secret in the center column.
    ///
    /// Setting this clears ``revealedValue`` and ``cachedHistory`` —
    /// changing selection re-masks the previous secret (Decision 4).
    var selectedSecretKey: String? {
        didSet {
            if selectedSecretKey != oldValue {
                revealedValue = nil
                revealedNotes = nil
                cachedHistory = []
            }
        }
    }

    /// The decrypted plaintext for the selected secret while it is revealed.
    ///
    /// `nil` when no secret is selected, when the key mismatch guard fires,
    /// or after selection changes re-masks it. Only ever the value for
    /// ``selectedSecretKey`` — staleness is impossible because setting
    /// `selectedSecretKey` unconditionally clears this field first.
    ///
    /// `internal` (not `private(set)`): the mutation intents that clear it on
    /// rotate/edit live in `WorkshopModel+Mutations.swift`, a separate file in
    /// the same module (the `Conduit`/`Conduit+Remote.swift` split precedent —
    /// Swift's `private` is file-scoped even within one type).
    var revealedValue: String?

    /// The decrypted notes for the selected secret while it is revealed.
    ///
    /// Set alongside ``revealedValue`` by ``reveal(key:inScope:)`` and cleared
    /// by the same selection-change cascade — notes live in the encrypted
    /// payload and follow the same masking discipline (Decision 4). `internal`
    /// for the same cross-file reason as ``revealedValue``.
    var revealedNotes: String?

    /// Informational result of the last action (e.g. a rescan summary).
    ///
    /// Distinct from ``errorMessage``: this is a success line, not a failure.
    /// The window renders it in the same bottom status surface. `internal`
    /// (not `private(set)`): the creation announces
    /// (`WorkshopModel+Mutations.swift`) and the jump announce
    /// (`WorkshopModel+Waymarking.swift`) both set it from their own files —
    /// the `Conduit`/`Conduit+Remote.swift` split precedent.
    var statusMessage: String?

    /// Rotation-history entries for the selected secret.
    private(set) var cachedHistory: [CommitInfo] = []

    /// Human-readable description of the most recent failure, for the window
    /// to surface; `nil` when the last operation succeeded.
    var errorMessage: String?

    /// File-based age key from `SHARIBAKO_AGE_KEY`; `nil` selects the Keychain path.
    ///
    /// The dev bypass for unsigned builds (Decision 7); AT-02's reveal
    /// selects its provider through ``makeAgeKeyProvider()``.
    let devAgeKeyPath: URL?

    /// Holds a pending materialize diff that requires explicit confirmation to overwrite.
    private(set) var pendingDiff: MaterializeDiff?

    /// A pending Materialize-all-stale plan awaiting confirmation, or `nil`
    /// (ho-06.2 AT-02, Decision 3).
    ///
    /// Set by ``requestMaterializeAllStale()`` (`WorkshopModel+Heal.swift`); the
    /// window presents a confirmation listing the drifted scopes and their
    /// target paths and calls ``confirmMaterializeAllStale()`` on approval or
    /// ``dismissAllStale()`` on cancel. `internal` (not `private(set)`) for the
    /// same cross-file-extension reason as ``driftReports`` — its mutators live
    /// in the heal extension file.
    var allStalePlan: AllStalePlan?

    /// A pending scope deletion awaiting confirmation, or `nil` (ho-06.7).
    ///
    /// Set by ``requestDeleteSelectedScope()`` (`WorkshopModel+Mutations.swift`);
    /// the window presents a system-rendered destructive confirmation naming the
    /// scope and its secret count and calls ``confirmDeleteScope()`` on approval
    /// or ``dismissScopeDeletion()`` on cancel. `internal` (not `private(set)`)
    /// for the same cross-file-extension reason as ``allStalePlan`` — its mutators
    /// live in the mutations extension file.
    var pendingScopeDeletion: ScopeDeletion?

    /// A pending single-secret deletion awaiting confirmation, or `nil` (ho-06.7).
    ///
    /// Set by ``requestDeleteSelectedSecret()`` (`WorkshopModel+Mutations.swift`);
    /// the window presents a system-rendered destructive confirmation naming the
    /// scope/key and calls ``confirmDeleteSecret()`` on approval or
    /// ``dismissSecretDeletion()`` on cancel. `internal` for the same
    /// cross-file-extension reason as ``pendingScopeDeletion``.
    var pendingSecretDeletion: SecretDeletion?

    /// The result of the last "Preview .env" action, or `nil` before one has
    /// run (ho-06.1 AT-03, Decision 5).
    ///
    /// Set by ``previewEnv()`` (`WorkshopModel+Preview.swift`); presenting the
    /// sheet is driven by this becoming non-nil, dismissing it by setting this
    /// back to `nil`. `internal` (not `private(set)`) for the same
    /// cross-file-extension reason as ``statusMessage`` — the preview intent
    /// lives in its own extension file, following the `Conduit` +
    /// `Conduit+Remote.swift` precedent.
    var envPreview: EnvPreviewResult?

    /// The resolved scan roots (from the GUI config file).
    ///
    /// Populated at init from `~/Library/Application Support/Sharibako/config.yaml`
    /// and updated when ``rescan()`` persists a new root. `var` (not `private(set)`)
    /// so tests can inject roots directly without touching the filesystem config.
    var scanRoots: [URL] = []

    /// The resolved GUI config file URL, fixed at init from the injected `home`.
    ///
    /// Every config read AND write goes through this URL — never through a
    /// freshly-resolved default — so tests that inject a temp `home` can never
    /// touch the live user config.
    let configURL: URL

    /// The injected (or live) home directory, retained for
    /// `vaultDirectoryShortDescription` (`WorkshopModel+Waymarking.swift`) —
    /// the sidebar footer abbreviates the vault path against this, not the
    /// live `NSHomeDirectory()`, so injected-home tests never resolve against
    /// the real user's home (AT-02 Decision 3). `internal` (not `private`) so
    /// the waymarking extension file can read it.
    let home: URL

    /// The first-run wizard's own state (ho-06.3) — a nested `@Observable`
    /// object (`WorkshopModel+FirstRun.swift`) rather than another dozen
    /// top-level properties here: the wizard's page/key-mode/backup/root/
    /// remote fields are cohesive to the `.noVault` window alone and would
    /// otherwise crowd this already-long class for a state machine that only
    /// exists before a vault does. `let`, not `private(set) var` — the
    /// first-run intents mutate the instance's own fields; `WorkshopModel`
    /// never reassigns it.
    let firstRun = FirstRunState()

    /// `true` once ``completeFirstRun()`` (`WorkshopModel+FirstRun.swift`) has
    /// created the vault and flipped ``vaultState`` to `.open` — the named
    /// seam AT-02 consumes to offer the first ingest immediately (ho-06.3
    /// Decision 1 step 6); this ho does not build that invite. `internal`
    /// (not `private(set)`) for the same cross-file-extension reason as
    /// ``pendingScopeDeletion`` — its mutator lives in the first-run
    /// extension file.
    var firstRunCompleted = false

    /// The GUI ingest flow's own state (ho-06.3 AT-02).
    ///
    /// A nested `@Observable` object (`WorkshopModel+Ingest.swift`) mirroring
    /// ``firstRun``'s pattern: the scan proposal, per-key decisions, and
    /// scope ID/type are cohesive to the ingest sheet alone and would
    /// otherwise crowd this already-long class for a session that only
    /// exists while the sheet is up. `let`, not `private(set) var` — the
    /// ingest intents mutate the instance's own fields; `WorkshopModel`
    /// never reassigns it.
    let ingest = IngestState()

    /// The injected (or live) environment.
    ///
    /// Retained for ``WorkshopModel/completeFirstRun()``'s git-identity probe
    /// (`WorkshopModel+FirstRun.swift`, ho-06.3 Decision 8): that probe
    /// shells `git config user.email`, whose global-config lookup is
    /// sensitive to `HOME` — passing this through as `GUIShell.run`'s
    /// `environmentOverrides` lets tests isolate it from the real developer
    /// machine's own git identity (an injected-`HOME` test never resolves
    /// against the live global gitconfig) while production, whose
    /// `environment` defaults to the real `ProcessInfo`, sees no change in
    /// behavior at all.
    let processEnvironment: [String: String]

    /// Resolves the vault per `WorkshopConfig` precedence and loads its scopes.
    ///
    /// `environment` and `home` default to live process values; tests inject
    /// both to exercise every branch without mutating process state.
    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        let resolved = WorkshopConfig.resolveVaultURL(environment: environment, home: home)
        devAgeKeyPath = WorkshopConfig.resolveDevAgeKeyURL(environment: environment)
        configURL = WorkshopConfig.defaultConfigURL(home: home)
        self.home = home
        processEnvironment = environment
        scanRoots = WorkshopConfig.loadScanRoots(configURL: configURL)
        if WorkshopConfig.isVaultDirectory(resolved) {
            vaultState = .open(vaultURL: resolved)
            loadScopes()
        } else {
            vaultState = .noVault(expectedPath: resolved)
        }
    }
}

// MARK: - Scope listing and sidebar sections

extension WorkshopModel {
    /// Flips ``vaultState`` from `.noVault` to `.open` at `vaultURL` — the
    /// first-run wizard's seam (``completeFirstRun()``,
    /// `WorkshopModel+FirstRun.swift`) for the one mutation the v1
    /// fixed-at-init posture allows outside `init`. `internal`, declared here
    /// (not a public setter) so nothing else can silently rebind the vault
    /// after launch; the extension file calls this rather than writing
    /// ``vaultState`` directly, since `private(set)` is file-scoped and
    /// `WorkshopModel+FirstRun.swift` is a different file (the established
    /// cross-file-extension pattern).
    func bindOpenedVault(at vaultURL: URL) {
        vaultState = .open(vaultURL: vaultURL)
    }

    /// Replaces the cached scan report.
    ///
    /// The write seam `WorkshopModel+Ingest.swift`'s post-commit cache
    /// refresh uses — `private(set)` is file-scoped (the same reason
    /// ``bindOpenedVault(at:)`` exists above); declared here, not a public
    /// setter, so nothing else can silently overwrite the cache outside a
    /// real scan.
    func updateScanReport(_ report: ScanReport) {
        scanReport = report
    }

    /// Reloads the scope list from the open vault.
    ///
    /// A no-op in the `.noVault` state. Failures land in ``errorMessage``
    /// rather than throwing — the window stays up and says what went wrong.
    func loadScopes() {
        guard case .open(let vaultURL) = vaultState else { return }
        do {
            scopes = try VaultCore(vaultURL: vaultURL).listScopes()
            errorMessage = nil
        } catch {
            scopes = []
            errorMessage = Self.message(for: error)
        }
    }

    /// The sidebar's sections: one per `ScopeType` holding scopes, in fixed
    /// display order, with empty sections omitted.
    var scopeSections: [ScopeSection] {
        Self.sectionOrder.compactMap { type in
            let matching = scopes.filter { $0.type == type }
            guard !matching.isEmpty else { return nil }
            return ScopeSection(type: type, scopes: matching)
        }
    }

    /// Fixed sidebar ordering of the five scope categories.
    static let sectionOrder: [ScopeType] = [.projectDev, .projectProd, .service, .machine, .other]
}

// MARK: - Secret listing (AT-02)

extension WorkshopModel {
    /// The secrets cached for the currently selected scope.
    ///
    /// Empty when no scope is selected or after a listing error.
    var secrets: [SecretInfo] { cachedSecrets }

    /// Loads the secrets for the given scope and stores them in ``secrets``.
    ///
    /// Uses the no-encryption ``VaultCore/init(vaultURL:)`` seam — listing
    /// never decrypts. Failures land in ``errorMessage``.
    func loadSecrets(for scopeID: String) {
        guard case .open(let vaultURL) = vaultState else { return }
        do {
            guard let core = try? VaultCore(vaultURL: vaultURL) else { return }
            cachedSecrets = try core.inspect(scopeID)
            errorMessage = nil
        } catch {
            cachedSecrets = []
            errorMessage = Self.message(for: error)
        }
    }
}

// MARK: - Reveal (AT-02, Decision 4)

extension WorkshopModel {
    /// Decrypts the selected secret and stores the plaintext in ``revealedValue``.
    ///
    /// Mirrors the CLI's `GetCommand.fetchValue` flow (read only):
    /// 1. Build the age key provider (file-key when dev bypass is set; Keychain otherwise).
    /// 2. Load the identity, obtaining an `AgeKeyHandle`.
    /// 3. Construct `VaultCore(vaultURL:ageKeyURL:)` with the temp key file.
    /// 4. Call `getSecretContent(_:inScope:)` — value AND notes together, so
    ///    the detail pane can display notes alongside the revealed value.
    /// 5. `defer { handle.release() }` — runs on every exit path.
    ///
    /// A Touch ID cancellation or Keychain failure sets ``errorMessage`` and leaves
    /// the value masked (revealedValue stays `nil`). No auto-hide timer — the value
    /// stays revealed until ``selectedSecretKey`` or ``selectedScopeID`` changes
    /// (Decision 4).
    func reveal(key: String, inScope scopeID: String) {
        guard case .open(let vaultURL) = vaultState else { return }
        let provider = makeAgeKeyProvider()
        let handle: AgeKeyHandle
        do {
            handle = try provider.loadIdentity(reason: "Reveal \(key) from \(scopeID)")
        } catch {
            errorMessage = "Could not load age key: \(error)"
            return
        }
        defer { handle.release() }
        do {
            let core = try VaultCore(vaultURL: vaultURL, ageKeyURL: handle.url)
            let content = try core.getSecretContent(key, inScope: scopeID)
            revealedValue = content.value
            revealedNotes = content.notes
            errorMessage = nil
        } catch {
            revealedValue = nil
            revealedNotes = nil
            errorMessage = Self.message(for: error)
        }
    }

    /// Masks the current revealed value and notes without changing selection.
    ///
    /// Used by the detail pane's "Hide" control. Selection-change re-masking
    /// is handled automatically by the `selectedSecretKey` setter.
    func maskValue() {
        revealedValue = nil
        revealedNotes = nil
    }
}

// MARK: - History (AT-02, Decision 6)

extension WorkshopModel {
    /// The history entries cached for the currently selected secret.
    var history: [CommitInfo] { cachedHistory }

    /// Loads the git history for a secret file and stores it in ``history``.
    ///
    /// Calls ``Conduit/log(fileURL:)`` on the secret's on-disk path. Returns
    /// silently when the vault has no git repository; failures land in
    /// ``errorMessage``.
    func loadHistory(for key: String, inScope scopeID: String, kind: SecretInfo.Kind) {
        guard case .open(let vaultURL) = vaultState else { return }
        // Compute the file URL directly from the vault layout without going
        // through VaultLayout (internal to SharibakoCore). The layout is
        // documented as the stable public contract: scopes/<scopeID>/<key>.age
        // for direct values, scopes/<scopeID>/<key>.link for links.
        let fileExtension: String
        switch kind {
        case .value:
            fileExtension = "age"
        case .link:
            fileExtension = "link"
        }
        let fileURL =
            vaultURL
            .appendingPathComponent("scopes", isDirectory: true)
            .appendingPathComponent(scopeID, isDirectory: true)
            .appendingPathComponent("\(key).\(fileExtension)", isDirectory: false)
        do {
            let conduit = try Conduit(vaultURL: vaultURL)
            cachedHistory = try conduit.log(fileURL: fileURL)
            errorMessage = nil
        } catch let vaultError as VaultError {
            // Non-git vaults (no .git/) surface as gitInvocationFailed.
            // Degrade gracefully — no history is not a fatal state.
            if case .gitInvocationFailed = vaultError {
                cachedHistory = []
            } else {
                errorMessage = Self.message(for: vaultError)
            }
        } catch {
            errorMessage = Self.message(for: error)
        }
    }
}

// MARK: - Action intents (AT-03, Decision 5)

extension WorkshopModel {
    /// The cached marker for `scopeID`, or `nil` when the cache holds none.
    ///
    /// Reads the session scan cache (Decision 2) populated by
    /// ``performLaunchScan()`` / ``rescan(openPanel:)``. AT-02's
    /// jump-to-directory button and ho-06.2's sidebar glyphs read this — a
    /// cache hit means the marker's target directory is known without a fresh
    /// walk. Returns `nil` when no scan has run yet or no marker matches.
    func cachedMarker(forScope scopeID: String) -> ScopeMarker? {
        scanReport?.markers.first { $0.scope == scopeID }
    }

    /// Runs one non-blocking scan at window open to warm the scan cache
    /// (Decision 2), and resolves the sidebar footer's remote description
    /// (Decision 3).
    ///
    /// Called from the window's `.task` modifier so the window renders
    /// immediately and both fill in behind it. The remote resolution is a
    /// fast local git call and runs even when ``scanRoots`` is empty — it has
    /// nothing to do with scan roots — but still only when the vault is open
    /// and only once (skipped on a re-entrant call while ``remoteDescription``
    /// is already set, so Rescan does not re-shell for a value that cannot
    /// have changed mid-session). Quiet on success for both — the user did not
    /// trigger this, so it sets no ``statusMessage``; failures still land in
    /// ``errorMessage``. Guards re-entry against ``activity`` like every long
    /// intent. The scan walk runs through ``worker``.
    func performLaunchScan() async {
        guard activity == nil else { return }
        guard case .open(let vaultURL) = vaultState else { return }
        if remoteDescription == nil {
            resolveRemoteDescription(vaultURL: vaultURL)
        }
        guard !scanRoots.isEmpty else { return }
        activity = .scanning
        defer { activity = nil }
        let roots = scanRoots
        do {
            let report = try await worker.run {
                let core = try VaultCore(vaultURL: vaultURL)
                return try Materializer(vaultCore: core, vaultURL: vaultURL).scan(roots: roots)
            }
            scanReport = report
            errorMessage = nil
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// Resolves ``remoteDescription`` via ``Conduit/remoteURL()``.
    ///
    /// A synchronous, fast local git call (no network) — it does not warrant
    /// the ``worker``/``activity`` machinery the tree-walk and network intents
    /// use. A vault with no `.git/` or no `origin` and any `Conduit`
    /// construction failure both resolve to ``RemoteDescription/none`` rather
    /// than surfacing an error — the footer's job is to state the fact
    /// plainly, not to treat "no remote" as a failure.
    private func resolveRemoteDescription(vaultURL: URL) {
        guard let conduit = try? Conduit(vaultURL: vaultURL),
            let url = try? conduit.remoteURL()
        else {
            remoteDescription = RemoteDescription.none
            return
        }
        remoteDescription = .configured(url: url)
    }

    /// Materializes the selected scope's secrets into its marker's `.env` target.
    ///
    /// Async (Decision 1): decryption + file write run through ``worker`` off the
    /// main thread; the age key is acquired on the main actor first (it is user
    /// interaction, not CPU work) and only its `Sendable` handle URL crosses.
    /// Resolves the scope's marker from the scan cache (Decision 2); on a cache
    /// miss it runs one fresh scan through the worker, retries the lookup, and
    /// only then surfaces the marker-not-found error. On drift, stores the diff
    /// in ``pendingDiff`` and returns without writing — the view presents a
    /// confirmation dialog and calls this again with `force: true` on approval
    /// (Decision 5: never overwrite drift silently, mirror the CLI's `--force` gate).
    func materializeSelectedScope(force: Bool = false) async {
        guard activity == nil else { return }
        guard case .open(let vaultURL) = vaultState,
            let scopeID = selectedScopeID
        else { return }
        statusMessage = nil
        activity = .materializing
        defer { activity = nil }
        let provider = makeAgeKeyProvider()
        let handle: AgeKeyHandle
        do {
            handle = try provider.loadIdentity(reason: "Decrypt secrets for materialize")
        } catch {
            errorMessage = "Could not load age key: \(error)"
            return
        }
        do {
            let marker = try await resolveMarkerFromCache(forScope: scopeID, vaultURL: vaultURL)
            let keyURL = handle.url
            let result = try await worker.run {
                let core = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
                let materializer = Materializer(vaultCore: core, vaultURL: vaultURL)
                return try materializer.materialize(marker: marker, overwriteDrift: force)
            }
            handle.release()
            applyMaterializeResult(result)
        } catch {
            handle.release()
            errorMessage = Self.message(for: error)
        }
    }

    /// Resolves the scope's marker from the cache, falling back to one fresh
    /// scan on a miss (Decision 2).
    ///
    /// A cache hit avoids re-walking the scan root per materialize. A miss —
    /// the marker moved or was deleted since the last scan, or the cache is
    /// cold — runs exactly one fresh scan through ``worker``, updates the cache,
    /// and retries the lookup before letting the marker-not-found error surface.
    ///
    /// `internal` (not `private`): ``previewEnv()`` (`WorkshopModel+Preview.swift`,
    /// AT-03) resolves markers the same way materialize does, so "Preview
    /// .env" and "Materialize" always agree on which marker they're
    /// targeting — the `Conduit`/`Conduit+Remote.swift` cross-file-extension
    /// precedent.
    func resolveMarkerFromCache(
        forScope scopeID: String,
        vaultURL: URL
    ) async throws -> ScopeMarker {
        if let cached = cachedMarker(forScope: scopeID) {
            return cached
        }
        let roots = scanRoots
        let report = try await worker.run {
            let core = try VaultCore(vaultURL: vaultURL)
            return try Materializer(vaultCore: core, vaultURL: vaultURL).scan(roots: roots)
        }
        scanReport = report
        if let refreshed = cachedMarker(forScope: scopeID) {
            return refreshed
        }
        let hint = roots.first ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        throw VaultError.markerNotFound(startingFrom: hint)
    }

    /// Applies a materialize outcome to published state (main-actor).
    ///
    /// Split from ``materializeSelectedScope(force:)`` so the awaited worker
    /// call stays a single expression. Every outcome visibly concludes
    /// (dogfood-gate finding: a silent success reads as a broken button).
    private func applyMaterializeResult(_ result: MaterializeResult) {
        switch result {
        case .diffPending(let diff):
            // Surface the diff; require explicit confirmation before re-running with force.
            pendingDiff = diff
        case .wrote(let path, let keysWritten):
            pendingDiff = nil
            refreshDriftForSelectedScopeAfterWrite()
            let count = keysWritten.count
            statusMessage = "Wrote \(count) secret\(count == 1 ? "" : "s") to \(path.path)."
            errorMessage = nil
        case .unchanged(let path):
            // CLI parity: `sharibako materialize` says "already up to date".
            pendingDiff = nil
            refreshDriftForSelectedScopeAfterWrite()
            statusMessage = "Already up to date: \(path.path)"
            errorMessage = nil
        }
    }

    /// Dismisses the pending diff (user chose not to overwrite drift).
    func dismissPendingDiff() {
        pendingDiff = nil
    }

    /// Commits pending vault changes and pushes to the remote.
    ///
    /// Async (Decision 1): `git commit`/`push` is network I/O that beach-balls
    /// exactly like a scan, so it runs through ``worker`` off the main thread.
    /// A vault with no configured remote commits locally and no-ops the push
    /// (clean no-op, not an error — mirrors the CLI's SyncCommand posture).
    /// Push rejections and conflicts map to ``errorMessage``; every other
    /// outcome reports through ``statusMessage`` so the button visibly
    /// concludes even on a no-op (dogfood-gate finding).
    func sync() async {
        guard activity == nil else { return }
        guard case .open(let vaultURL) = vaultState else { return }
        statusMessage = nil
        activity = .syncing
        defer { activity = nil }
        do {
            let (commitResult, pushResult) = try await worker.run {
                let conduit = try Conduit(vaultURL: vaultURL)
                let commit = try conduit.commit(message: "sharibako auto-commit")
                let push = try conduit.push()
                return (commit, push)
            }
            if case .rejected(let reason) = pushResult {
                errorMessage = "Push rejected: \(reason). Resolve remotely, then sync again."
                return
            }
            statusMessage = Self.syncStatusMessage(commit: commitResult, push: pushResult)
            errorMessage = nil
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// Builds the sync status line from the commit + push outcomes.
    ///
    /// Mirrors the CLI SyncCommand's vocabulary ("nothing to commit",
    /// "committed <sha>, pushed <n>"). `.rejected` never reaches here — the
    /// caller routes it to ``errorMessage``.
    private static func syncStatusMessage(commit: CommitResult, push: PushResult) -> String {
        let commitPart: String
        switch commit {
        case .success(let sha):
            commitPart = "Committed \(sha.prefix(7))"
        case .nothingToCommit:
            commitPart = "Nothing to commit"
        }
        switch push {
        case .success(let count):
            return "\(commitPart); pushed \(count) commit\(count == 1 ? "" : "s")."
        case .upToDate:
            return "\(commitPart); remote already up to date."
        case .noRemote:
            return "\(commitPart); no remote configured."
        case .rejected:
            // Unreachable by contract; keep the switch exhaustive.
            return "\(commitPart)."
        }
    }

    /// Rescans for `.sharibako` markers.
    ///
    /// When no scan root is configured, `openPanel` is called to let the view
    /// present an `NSOpenPanel` directory picker; on a nil return (user cancelled),
    /// does nothing. On a chosen root, persists it via
    /// ``WorkshopConfig/persistScanRoot(_:configURL:)`` against the model's own
    /// ``configURL`` — never a freshly-resolved default, so injected-home tests
    /// stay isolated from the live user config. After picking or when roots are
    /// already configured, runs `Materializer.scan(roots:)` and reports the
    /// result through ``statusMessage`` so the button visibly did something
    /// (Decision 3).
    ///
    /// Async (Decision 1): the directory picker runs on the main actor (user
    /// interaction), then the tree walk hops to ``worker``. The report is stored
    /// in the ``scanReport`` cache (Decision 2) so materialize and the
    /// jump-to-directory button read fresh markers after a Rescan.
    func rescan(openPanel: (() -> URL?)? = nil) async {
        guard activity == nil else { return }
        guard case .open(let vaultURL) = vaultState else { return }
        statusMessage = nil
        if scanRoots.isEmpty {
            guard let panel = openPanel, let chosen = panel() else {
                return
            }
            do {
                try WorkshopConfig.persistScanRoot(chosen, configURL: configURL)
                scanRoots = WorkshopConfig.loadScanRoots(configURL: configURL)
            } catch {
                errorMessage = Self.message(for: error)
                return
            }
        }
        activity = .scanning
        defer { activity = nil }
        let roots = scanRoots
        do {
            let report = try await worker.run {
                let core = try VaultCore(vaultURL: vaultURL)
                return try Materializer(vaultCore: core, vaultURL: vaultURL).scan(roots: roots)
            }
            scanReport = report
            let markerCount = report.markers.count
            let rootCount = roots.count
            statusMessage =
                "Scan found \(markerCount) marker\(markerCount == 1 ? "" : "s") "
                + "in \(rootCount) root\(rootCount == 1 ? "" : "s")."
            errorMessage = nil
        } catch {
            errorMessage = Self.message(for: error)
        }
    }
}

// MARK: - Age key provider and error messages

extension WorkshopModel {
    /// Builds the age-key provider for decrypt operations (used from AT-02 on).
    ///
    /// The file provider wins when `SHARIBAKO_AGE_KEY` is set (the dev bypass,
    /// Decision 7); otherwise the GUI's own Keychain adapter (Decision 1).
    func makeAgeKeyProvider() -> any GUIAgeKeyProvider {
        if let devAgeKeyPath {
            return GUIFileAgeKeyProvider(path: devAgeKeyPath)
        }
        return GUIKeychainAgeKeyProvider()
    }

    /// Renders an error as a user-facing sentence.
    ///
    /// Dispatches to `vaultErrorMessage` for known `VaultError` cases;
    /// everything else falls through to a generic description.
    static func message(for error: Error) -> String {
        guard let vaultError = error as? VaultError else {
            return "Unexpected error: \(error)"
        }
        return Self.vaultErrorMessage(for: vaultError)
    }

    /// Names the `VaultError` cases the model can surface; split from
    /// `message(for:)` to keep cyclomatic complexity within the linter ceiling.
    private static func vaultErrorMessage(for vaultError: VaultError) -> String {
        switch vaultError {
        case .vaultNotFound(let path):
            return "No vault found at \(path.path)."
        case .yamlDecodeError(let path, _):
            return "Could not read \(path.lastPathComponent) — the file is not valid YAML."
        case .fileSystemError(let path, _):
            return "A filesystem operation failed at \(path.path)."
        case .secretNotFound(let scope, let key):
            return "Secret '\(key)' not found in scope '\(scope)'."
        case .scopeNotFound(let id):
            return "Scope '\(id)' not found."
        case .scopeAlreadyExists(let id):
            return "A scope named '\(id)' already exists."
        case .sharedEntryExists(let id):
            return "A shared entry named '\(id)' already exists."
        case .sharedEntryNotFound(let id):
            return "Shared entry '\(id)' not found."
        case .markerNotFound:
            return "No .sharibako marker found for this scope in the configured scan roots."
        case .ageInvocationFailed(_, let stderr):
            return "Encryption failed: \(stderr.prefix(120))"
        case .gitInvocationFailed(_, let stderr):
            return "Git error: \(stderr.prefix(120))"
        default:
            return "Vault error: \(vaultError)"
        }
    }
}

// MARK: - Sidebar section type

/// One sidebar section: a scope category and its member scopes.
struct ScopeSection: Equatable, Identifiable {
    /// The category this section groups.
    let type: ScopeType

    /// Scopes of that category, in vault order (sorted by identity).
    let scopes: [ScopeMetadata]

    /// Stable identity for SwiftUI lists.
    var id: String { type.rawValue }

    /// The section header text.
    var title: String {
        switch type {
        case .projectDev:
            return "Projects — dev"
        case .projectProd:
            return "Projects — prod"
        case .service:
            return "Services"
        case .machine:
            return "Machines"
        case .other:
            return "Other"
        }
    }
}
