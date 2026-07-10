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
/// All methods run synchronously on the main actor: vault operations are
/// local, fast filesystem work (Decision 2 keeps v1 synchronous).
@Observable
@MainActor
final class WorkshopModel {
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
    private(set) var revealedValue: String?

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
        if WorkshopConfig.isVaultDirectory(resolved) {
            vaultState = .open(vaultURL: resolved)
            loadScopes()
        } else {
            vaultState = .noVault(expectedPath: resolved)
        }
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

    // MARK: - Secret listing (AT-02)

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

    // MARK: - Reveal (AT-02, Decision 4)

    /// Decrypts the selected secret and stores the plaintext in ``revealedValue``.
    ///
    /// Mirrors the CLI's `GetCommand.fetchValue` flow (read only):
    /// 1. Build the age key provider (file-key when dev bypass is set; Keychain otherwise).
    /// 2. Load the identity, obtaining an `AgeKeyHandle`.
    /// 3. Construct `VaultCore(vaultURL:ageKeyURL:)` with the temp key file.
    /// 4. Call `getValue(_:inScope:)`.
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
            let plaintext = try core.getValue(key, inScope: scopeID)
            revealedValue = plaintext
            errorMessage = nil
        } catch {
            revealedValue = nil
            errorMessage = Self.message(for: error)
        }
    }

    /// Masks the current revealed value without changing selection.
    ///
    /// Used by the detail pane's "Hide" control. Selection-change re-masking
    /// is handled automatically by the `selectedSecretKey` setter.
    func maskValue() {
        revealedValue = nil
    }

    // MARK: - History (AT-02, Decision 6)

    /// The history entries cached for the currently selected secret.
    var history: [CommitInfo] { cachedHistory }

    /// Loads the git history for a secret file and stores it in ``history``.
    ///
    /// Calls ``Conduit/log(fileURL:)`` on the secret's on-disk path. Returns
    /// silently when the vault has no git repository; failures land in
    /// ``errorMessage``.
    func loadHistory(for key: String, inScope scopeID: String, kind: SecretInfo.Kind) {
        guard case .open(let vaultURL) = vaultState else { return }
        let fileURL: URL
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
        fileURL =
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

    // MARK: - Sidebar sections

    /// The sidebar's sections: one per `ScopeType` holding scopes, in fixed
    /// display order, with empty sections omitted.
    var scopeSections: [ScopeSection] {
        Self.sectionOrder.compactMap { type in
            let matching = scopes.filter { $0.type == type }
            guard !matching.isEmpty else { return nil }
            return ScopeSection(type: type, scopes: matching)
        }
    }

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

    /// Fixed sidebar ordering of the five scope categories.
    static let sectionOrder: [ScopeType] = [.projectDev, .projectProd, .service, .machine, .other]

    /// Renders an error as a user-facing sentence.
    ///
    /// Names the cases the model can hit in AT-01; everything else falls
    /// through to a generic description rather than string-parsing.
    static func message(for error: Error) -> String {
        guard let vaultError = error as? VaultError else {
            return "Unexpected error: \(error)"
        }
        switch vaultError {
        case .vaultNotFound(let path):
            return "No vault found at \(path.path)."
        case .yamlDecodeError(let path, _):
            return "Could not read \(path.lastPathComponent) — the file is not valid YAML."
        case .fileSystemError(let path, _):
            return "A filesystem operation failed at \(path.path)."
        default:
            return "Vault error: \(vaultError)"
        }
    }
}

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
