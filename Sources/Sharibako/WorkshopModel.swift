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
    var selectedScopeID: String?

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
