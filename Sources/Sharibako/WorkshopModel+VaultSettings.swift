import Foundation
import SharibakoCore

/// The vault's two settings the Workshop now edits (ho-06.10 Decision 8,
/// AT-04): **Remote…**, the vault's git remote, and **Scan folders…**, the
/// folders searched for projects. Both open a sheet from VAULT, and the
/// sidebar footer — which reads ``WorkshopModel/remoteDescription`` and
/// ``WorkshopModel/scanRoots`` — reflects every change at once.
///
/// Split from `WorkshopModel+Verbs.swift` under SwiftLint's length ceilings,
/// the `Conduit`/`Conduit+Remote.swift` precedent.
extension WorkshopModel {
    /// The Remote… sheet's state while it is open.
    struct RemoteSheetState: Equatable {
        /// The URL as typed so far.
        var draft: String
        /// Why the last Save was refused, shown under the field; `nil` when
        /// nothing was refused.
        var error: String?
    }

    // MARK: - Remote… (Required Change 4)

    /// The configured remote's URL, or `nil` when there is none (or it has
    /// not been read yet).
    var configuredRemoteURL: String? {
        guard case .configured(let url) = remoteDescription else { return nil }
        return url
    }

    /// The sheet's current-remote line: the URL, or "No remote".
    var remoteSheetCurrent: String {
        configuredRemoteURL ?? "No remote"
    }

    /// Whether the sheet's Remove applies — only with a remote configured.
    var canRemoveRemote: Bool {
        configuredRemoteURL != nil
    }

    /// Opens the Remote… sheet with the field filled from the current remote.
    func openRemoteSheet() {
        guard case .open = vaultState else { return }
        remoteSheet = RemoteSheetState(draft: configuredRemoteURL ?? "", error: nil)
    }

    /// Closes the Remote… sheet without changing anything.
    func dismissRemoteSheet() {
        remoteSheet = nil
    }

    /// Sets the vault's remote to the sheet's draft.
    ///
    /// Through ``Conduit/setRemote(_:)`` — the same transport allowlist the
    /// first-run wizard's remote page uses, refused in the same words
    /// ("Remote rejected: …") under the field, the sheet left open. On
    /// success the sheet closes, the footer re-reads the remote, and the
    /// change is announced.
    func saveRemote() {
        guard case .open(let vaultURL) = vaultState, var sheet = remoteSheet else { return }
        let url = sheet.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            sheet.error = "Enter the remote's URL, or use Remove to have none."
            remoteSheet = sheet
            return
        }
        do {
            try Conduit(vaultURL: vaultURL).setRemote(url)
        } catch let error as VaultError {
            if case .remoteURLRejected(_, let reason) = error {
                sheet.error = "Remote rejected: \(reason)"
            } else {
                sheet.error = Self.message(for: error)
            }
            remoteSheet = sheet
            return
        } catch {
            sheet.error = Self.message(for: error)
            remoteSheet = sheet
            return
        }
        resolveRemoteDescription(vaultURL: vaultURL)
        remoteSheet = nil
        statusMessage = "Remote set to \(url). Sync backs the vault up there."
        errorMessage = nil
    }

    /// Removes the vault's remote (``Conduit/removeRemote()``); Sync then
    /// commits on this Mac only.
    func removeRemote() {
        guard case .open(let vaultURL) = vaultState, remoteSheet != nil else { return }
        do {
            try Conduit(vaultURL: vaultURL).removeRemote()
        } catch {
            remoteSheet?.error = Self.message(for: error)
            return
        }
        resolveRemoteDescription(vaultURL: vaultURL)
        remoteSheet = nil
        statusMessage = "Remote removed. Sync now keeps the vault's history on this Mac only."
        errorMessage = nil
    }

    // MARK: - Scan folders… (Required Change 5)

    /// The Scan folders… sheet's empty state.
    static let noScanFoldersText = "No folders are scanned yet. Add the folder where you keep your projects."

    /// Opens the Scan folders… sheet, re-reading the list from `config.yaml`
    /// first (the file is truth — the same rule Rescan follows).
    func openScanFolders() {
        guard case .open = vaultState else { return }
        let configRoots = WorkshopConfig.loadScanRoots(configURL: configURL)
        if !configRoots.isEmpty {
            scanRoots = configRoots
        }
        isScanFoldersSheetPresented = true
    }

    /// Adds `folder` to the scan folders and persists the list.
    ///
    /// A folder already listed is not added twice. Announces either way.
    func addScanFolder(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        guard !scanRoots.contains(where: { $0.standardizedFileURL.path == path }) else {
            statusMessage = "\(abbreviatedPath(folder)) is already scanned."
            return
        }
        do {
            try WorkshopConfig.persistScanRoots(scanRoots + [folder], configURL: configURL)
        } catch {
            errorMessage = Self.message(for: error)
            return
        }
        scanRoots = WorkshopConfig.loadScanRoots(configURL: configURL)
        statusMessage = "Added \(abbreviatedPath(folder)) to the scan folders."
        errorMessage = nil
    }

    /// Removes `folder` from the scan folders and persists the list.
    func removeScanFolder(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        do {
            try WorkshopConfig.removeScanRoot(folder, configURL: configURL)
        } catch {
            errorMessage = Self.message(for: error)
            return
        }
        scanRoots.removeAll { $0.standardizedFileURL.path == path }
        statusMessage = "Removed \(abbreviatedPath(folder)) from the scan folders."
        errorMessage = nil
    }

    /// Closes the Scan folders… sheet and rescans over the new list.
    ///
    /// With no folder left a scan cannot run, so the scan's findings are
    /// cleared instead and the window says so.
    func closeScanFolders() async {
        guard isScanFoldersSheetPresented else { return }
        isScanFoldersSheetPresented = false
        guard !scanRoots.isEmpty else {
            clearScanCaches()
            statusMessage = "No folders are scanned — add one with Scan folders… to find projects."
            errorMessage = nil
            return
        }
        await rescan()
    }
}
