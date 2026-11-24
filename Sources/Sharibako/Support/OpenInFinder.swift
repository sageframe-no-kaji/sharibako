import AppKit
import Foundation

/// Open in Finder, shared by every surface that offers it (ho-06.9 AT-02
/// Required Change 7): the Not-protected and Problem pages now, the action
/// column's selection verbs in AT-03.
///
/// One helper so the verb behaves the same everywhere — Finder opens the
/// folder, and the status line says so (every action announces; ho-06.1
/// AT-02 Decision 3). The announce is ``WorkshopModel/announceJump(to:)``,
/// tested; the `NSWorkspace` call opens a real Finder window and is not
/// headlessly drivable, so this file is coverage-excluded (ho-05 Decision 8).
extension WorkshopModel {
    /// Opens `url` in Finder and announces it in the status line.
    func openInFinder(_ url: URL) {
        NSWorkspace.shared.open(url)
        announceJump(to: url)
    }
}
