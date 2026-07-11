import Foundation
import SharibakoCore

/// Waymarking reads for the sidebar footer, the detail pane's marker target,
/// and the jump-to-directory toolbar button (ho-06.1 AT-02 Decision 3).
///
/// Kept in a separate file so `WorkshopModel.swift` stays under SwiftLint's
/// `file_length` ceiling and this feature's reads stay visually grouped.
/// Follows the `Conduit` + `Conduit+Remote.swift` precedent. Everything here
/// is a read over state `WorkshopModel.swift` already owns (``vaultState``,
/// ``remoteDescription``, the scan cache via ``cachedMarker(forScope:)``) —
/// no new published state, no re-scanning for display.
extension WorkshopModel {
    /// The open vault's directory, abbreviated for `home` (e.g.
    /// `~/.sharibako/vault`), for the sidebar footer's short form.
    ///
    /// `nil` in the `.noVault` state — the footer only renders when a vault
    /// is open. Abbreviation is computed against the model's own injected
    /// `home`, never `NSHomeDirectory()`, so tests stay isolated.
    var vaultDirectoryShortDescription: String? {
        guard case .open(let vaultURL) = vaultState else { return nil }
        return Self.abbreviate(vaultURL, against: home)
    }

    /// The open vault's directory as a full, non-abbreviated path — the
    /// sidebar footer's tooltip content.
    var vaultDirectoryFullDescription: String? {
        guard case .open(let vaultURL) = vaultState else { return nil }
        return vaultURL.path
    }

    /// The vault's remote in short form for the sidebar footer, or `nil`
    /// while ``WorkshopModel/remoteDescription`` has not resolved yet.
    ///
    /// Distinct from "no remote": an unresolved cache renders no remote line
    /// at all rather than a false "no remote" the launch scan hasn't had time
    /// to disprove yet.
    var remoteShortDescription: String? {
        guard let remoteDescription else { return nil }
        switch remoteDescription {
        case .configured(let url):
            return url
        case .none:
            return "No remote"
        }
    }

    /// The vault's remote in full form — the sidebar footer tooltip content.
    ///
    /// Same resolved/unresolved distinction as ``remoteShortDescription``.
    var remoteFullDescription: String? {
        guard let remoteDescription else { return nil }
        switch remoteDescription {
        case .configured(let url):
            return url
        case .none:
            return "No remote configured"
        }
    }

    /// The configured scan roots in short form for the sidebar footer, each
    /// abbreviated against the model's injected `home` (ho-06.2 AT-03 Decision
    /// 5).
    ///
    /// Renders *all* roots — `scanRoots` is already `[URL]`, so a user who
    /// hand-edits `config.yaml` to add roots sees them reflected — joined for
    /// display. A plain "No scan root configured" when empty. Read-only
    /// visibility; the single-root pick stays the existing `NSOpenPanel`-on-empty
    /// flow (multi-root *management* is an owed near-term ho, not this one).
    var scanRootsShortDescription: String {
        guard !scanRoots.isEmpty else { return "No scan root configured" }
        return scanRoots.map { Self.abbreviate($0, against: home) }.joined(separator: ", ")
    }

    /// The configured scan roots as full, non-abbreviated paths — the sidebar
    /// footer's tooltip content; `nil` when no root is configured.
    var scanRootsFullDescription: String? {
        guard !scanRoots.isEmpty else { return nil }
        return scanRoots.map(\.path).joined(separator: "\n")
    }

    /// Abbreviates `url` against `home` with a leading `~`, or returns the
    /// full path unchanged when `url` does not fall under `home`.
    ///
    /// A hand-rolled equivalent of `NSString.abbreviatingWithTildeInPath` that
    /// takes its home directory as a parameter instead of reading
    /// `NSHomeDirectory()` — the live-process value tests must never touch.
    private static func abbreviate(_ url: URL, against home: URL) -> String {
        let homePath = home.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path
        guard targetPath == homePath || targetPath.hasPrefix(homePath + "/") else {
            return targetPath
        }
        let suffix = targetPath.dropFirst(homePath.count)
        return "~" + suffix
    }

    /// The directory jump-to-directory should open for `scopeID`, or `nil`
    /// when the cache holds no marker for it.
    ///
    /// Reads ``cachedMarker(forScope:)`` — never re-scans for display (that
    /// miss-fallback belongs to materialize, not to this button). The marker
    /// directory (where `.sharibako` lives), not the materialize target file,
    /// is what "jump to this scope's project" means.
    func jumpTargetDirectory(forScope scopeID: String) -> URL? {
        cachedMarker(forScope: scopeID)?.markerURL.deletingLastPathComponent()
    }

    /// Explains why jump-to-directory is disabled for the current selection,
    /// or `nil` when it is enabled — the toolbar button's help text names the
    /// reason rather than just going gray (AT-02 Decision 3).
    var jumpDisabledReason: String? {
        guard let selectedScopeID else {
            return "Select a scope to jump to its directory"
        }
        guard cachedMarker(forScope: selectedScopeID) != nil else {
            return scanReport == nil
                ? "Not scanned yet — rescan to find this scope's directory"
                : "No marker found for this scope in the configured scan roots"
        }
        return nil
    }

    /// Records that jump-to-directory opened `url` (AT-02 Decision 3 —
    /// every action announces).
    ///
    /// Called by the view after `NSWorkspace` opens Finder there, since the
    /// system call itself is not test-drivable.
    func announceJump(to url: URL) {
        statusMessage = "Opened \(url.path) in Finder."
        errorMessage = nil
    }

    /// The detail pane's marker-target read for `scopeID`, from the scan
    /// cache only — never a fresh scan (that miss-fallback belongs to
    /// materialize, not to display).
    enum MarkerTargetDescription: Equatable {
        /// No scan has populated the cache yet.
        case notScanned
        /// The cache is warm but holds no marker for this scope.
        case notFound
        /// A cached marker names both its own directory and the file
        /// materialize would write.
        case found(markerDirectory: URL, targetURL: URL)
    }

    /// Resolves ``MarkerTargetDescription`` for the selected scope, reading
    /// ``cachedMarker(forScope:)`` (AT-02 Decision 3's two honest empty
    /// states: "not scanned yet" vs. a warm-cache miss).
    func markerTargetDescription(forScope scopeID: String) -> MarkerTargetDescription {
        guard let marker = cachedMarker(forScope: scopeID) else {
            return scanReport == nil ? .notScanned : .notFound
        }
        return .found(
            markerDirectory: marker.markerURL.deletingLastPathComponent(),
            targetURL: marker.targetURL
        )
    }
}
