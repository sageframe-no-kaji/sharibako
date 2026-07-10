import Foundation
import SharibakoCore

/// The "Preview .env" intent (ho-06.1 AT-03, Decision 5).
///
/// Renders exactly what ``WorkshopModel/materializeSelectedScope(force:)``
/// would write for the selected scope, without writing anything — a
/// materialize dry-run and the scope-level reveal surface. Split into its own
/// file for the same reason as `WorkshopModel+Mutations.swift` and
/// `WorkshopModel+Waymarking.swift`: keeps `WorkshopModel.swift` under
/// SwiftLint's `file_length` ceiling and groups this feature's logic (the
/// `Conduit` + `Conduit+Remote.swift` precedent).
extension WorkshopModel {
    /// Renders the selected scope's `.env` composition behind one Touch ID
    /// and stores it in ``WorkshopModel/envPreview``.
    ///
    /// Async (Decision 1): `Materializer.preview` decrypts every scope
    /// secret — the same weight as materialize — so the compose work runs
    /// through ``worker`` off the main thread; the age key is acquired on the
    /// main actor first, riding the shared `LAContext`'s reuse window
    /// (Decision 5) the same way every other key load does. Resolves the
    /// scope's marker from the AT-01 scan cache, falling back to one fresh
    /// scan on a miss — the same resolution ``materializeSelectedScope(force:)``
    /// uses, so "Preview .env" and "Materialize" always agree on which marker
    /// they're targeting.
    func previewEnv() async {
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
            handle = try provider.loadIdentity(reason: "Preview .env for \(scopeID)")
        } catch {
            errorMessage = "Could not load age key: \(error)"
            return
        }
        do {
            let marker = try await resolveMarkerFromCache(forScope: scopeID, vaultURL: vaultURL)
            let targetURL = try marker.validatedTargetURL()
            let keyURL = handle.url
            let content = try await worker.run {
                let core = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
                let materializer = Materializer(vaultCore: core, vaultURL: vaultURL)
                return try materializer.preview(marker: marker)
            }
            handle.release()
            envPreview = EnvPreviewResult(scopeID: scopeID, targetURL: targetURL, content: content)
            errorMessage = nil
        } catch {
            handle.release()
            errorMessage = Self.message(for: error)
        }
    }

    /// Dismisses the preview sheet.
    func dismissEnvPreview() {
        envPreview = nil
    }

    /// Whether "Preview .env" can run for the current selection — no scope
    /// selected, or the scan cache holds no marker for it, both disable the
    /// action (mirrors ``jumpDisabledReason`` — the toolbar button's help
    /// text names the reason rather than just going gray).
    var previewDisabledReason: String? {
        guard let selectedScopeID else {
            return "Select a scope to preview its .env composition"
        }
        guard cachedMarker(forScope: selectedScopeID) != nil else {
            return scanReport == nil
                ? "Not scanned yet — rescan to find this scope's directory"
                : "No marker found for this scope in the configured scan roots"
        }
        return nil
    }
}

/// The result of a "Preview .env" action: which scope, what target path
/// Materialize would write to, and the exact composed content.
struct EnvPreviewResult: Equatable {
    /// The scope this preview was rendered for.
    let scopeID: String
    /// The file Materialize would write for this scope.
    let targetURL: URL
    /// The exact composed `.env` text.
    let content: String
}
