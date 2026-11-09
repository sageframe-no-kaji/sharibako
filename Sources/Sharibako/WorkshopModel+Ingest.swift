import Foundation
import SharibakoCore

/// Choosing a folder to protect, and the first-run finish page's folder walk
/// (ho-06.3 Decision 6, reshaped by ho-06.10 Decision 6).
///
/// ho-06.10 retired the Protect sheet and its session: the project page is
/// the review (Decision 6), so "begin protecting this folder" is now simply
/// "select this folder" — its page lists every `.env` line with a choice, and
/// the protect intents (`WorkshopModel+Protect.swift`) commit from there.
/// What stays here is the hand-picked-folder path, which registers a scan
/// root before selecting, and the keyless candidate walk every scan and the
/// first-run finish page share.
///
/// Split out the way every other feature's intents are
/// (`WorkshopModel+Mutations.swift`, `+Heal.swift`, `+FirstRun.swift`) — the
/// `Conduit`/`Conduit+Remote.swift` precedent.
extension WorkshopModel {
    // MARK: - Choosing a folder

    /// Selects a folder the user picked by hand, wherever it sits.
    ///
    /// The ho-06.9 gate found the hand-picked path gone: Choose Other… left
    /// with the chooser and nothing replaced it. When no scan root already
    /// contains `directory`, the folder itself is registered as a root first —
    /// so its claim file survives the next launch's scan, closing the ho-06.3
    /// trap where a hand-picked project vanished on relaunch — then the roots
    /// are reloaded and re-scanned quietly, and the folder is selected
    /// (``beginIngest(directory:)``): its page is where it is protected.
    /// Registering the folder (not its parent) adds nothing the user did not
    /// point at.
    func protectFolder(_ directory: URL) async {
        guard activity == nil else { return }
        guard case .open(let vaultURL) = vaultState else { return }
        let folder = directory.standardizedFileURL
        let covered = scanRoots.contains { root in
            let rootPath = root.standardizedFileURL.path
            return folder.path == rootPath || folder.path.hasPrefix(rootPath + "/")
        }
        if !covered {
            do {
                try WorkshopConfig.persistScanRoot(folder, configURL: configURL)
                scanRoots = WorkshopConfig.loadScanRoots(configURL: configURL)
                activity = .scanning
                _ = try await scanMarkersAndCandidates(vaultURL: vaultURL, roots: scanRoots)
                activity = nil
            } catch {
                activity = nil
                errorMessage = Self.message(for: error)
                return
            }
        }
        beginIngest(directory: folder)
    }

    /// Selects a folder's row, with no sheet (ho-06.10 Decision 6).
    ///
    /// The row is the project its claim file names when the vault has it, the
    /// Problem row when the vault does not, else the folder as not yet
    /// protected.
    ///
    /// Reads the scan cache only; nothing is walked, read, or decrypted here —
    /// the page's own ``loadContent(for:)`` reads the lines. A candidate is
    /// selected by the URL ``candidates`` already holds when it holds one, so
    /// the selection equals the sidebar row's tag even when `directory`
    /// carries a trailing slash or a `..`. A no-op with no vault open.
    func beginIngest(directory: URL) {
        guard case .open = vaultState else { return }
        let folder = directory.standardizedFileURL
        let marker = scanReport?.markers.first {
            $0.markerURL.deletingLastPathComponent().standardizedFileURL.path == folder.path
        }
        if let marker {
            let known = scopes.contains { $0.identity == marker.scope }
            selection = known ? .project(scopeID: marker.scope) : .problem(markerPath: marker.markerURL.path)
            return
        }
        let candidate = candidates.first { $0.standardizedFileURL.path == folder.path }
        selection = .candidate(directory: candidate ?? folder)
    }

    // MARK: - Wizard hand-off

    /// Worker-routed shallow walk of `root` for `.env`-bearing directories —
    /// the finish page's own read of the seam AT-01 left (``firstRunCompleted``).
    ///
    /// Pure logic (``IngestCandidateScanner``) hops to ``worker`` since it
    /// walks the filesystem; never touches the age key — finding `.env`
    /// files needs no decryption. Non-throwing: an unreadable subdirectory
    /// mid-walk is skipped by the scanner itself rather than aborting the
    /// whole probe (the wizard's finish page treats "found nothing" and "hit
    /// something unreadable" the same way — a plain close, never a blocker
    /// for a user who already has a vault).
    func findFirstRunIngestCandidates(under root: URL) async -> [URL] {
        await worker.run { IngestCandidateScanner.findCandidates(under: root) }
    }
}

// MARK: - Candidate scanning (pure, off-main-actor-safe)

/// Pure directory-walk logic for `.env`-bearing folders: the first-run finish
/// page's preview (Required Change 5) and, since ho-06.9, the "Not protected"
/// half of every scan (``WorkshopModel/scanMarkersAndCandidates(vaultURL:roots:)``).
///
/// A plain `enum` (never instantiated), not a `WorkshopModel` static method:
/// it is called from inside `VaultWorker.run`'s `@Sendable` closure, off the
/// main actor, and a method on the `@MainActor` model would carry that
/// isolation into the closure.
enum IngestCandidateScanner {
    /// Maximum depth below `root` to walk (`root` itself is depth 0).
    ///
    /// Deep enough for real vault layouts (`<root>/<org>/<area>/<project>` —
    /// the gate found depth 2 missed `edelmore/apps/diary`-shaped paths that
    /// the unbounded marker scan reaches), still bounded so a wide root
    /// resolves fast; ``skippedDirectoryNames`` keeps the walk out of the
    /// dependency forests that make unbounded walks slow.
    static let maxDepth = 5

    /// Directory names never descended into: dependency and build-product
    /// forests that are huge, never hold the user's own projects, and would
    /// dominate the walk's cost (dotfolders are skipped separately).
    static let skippedDirectoryNames: Set<String> = [
        "node_modules", "Pods", "vendor", "DerivedData",
    ]

    /// File names whose presence marks a directory as a candidate — the
    /// value-bearing `.env` family `Materializer.ingest` reads (`.env.example`
    /// alone carries no values, so it does not qualify a directory).
    static let candidateEnvFileNames = [".env", ".env.local"]

    /// Returns every directory at or below `root` (within ``maxDepth``)
    /// that contains a `.env` file, sorted by path for stable display.
    static func findCandidates(under root: URL) -> [URL] {
        let fileManager = FileManager.default
        var results: [URL] = []
        walk(root, depth: 0, fileManager: fileManager, results: &results)
        return results.sorted { $0.path < $1.path }
    }

    /// Runs ``findCandidates(under:)`` across several roots, keeping only
    /// projects not yet in the vault.
    ///
    /// "Not yet in the vault" means no `.sharibako` marker in the directory
    /// (the "Not protected" section's population). Deduplicated by
    /// standardized path (overlapping roots would list a project twice),
    /// sorted for stable display.
    static func findUnboundCandidates(under roots: [URL]) -> [URL] {
        let fileManager = FileManager.default
        var seen = Set<String>()
        var results: [URL] = []
        for root in roots {
            for candidate in findCandidates(under: root) {
                let standardized = candidate.standardizedFileURL
                guard seen.insert(standardized.path).inserted else { continue }
                let markerURL = standardized.appendingPathComponent(".sharibako")
                guard !fileManager.fileExists(atPath: markerURL.path) else { continue }
                results.append(standardized)
            }
        }
        return results.sorted { $0.path < $1.path }
    }

    private static func walk(
        _ directory: URL, depth: Int, fileManager: FileManager, results: inout [URL]
    ) {
        guard depth <= maxDepth else { return }
        let hasEnvFile = candidateEnvFileNames.contains { name in
            fileManager.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
        if hasEnvFile {
            results.append(directory)
        }
        guard depth < maxDepth else { return }
        guard
            let children = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        else { return }
        for child in children {
            // Hidden directories (`.git`, dotfolders) have no reason to be
            // descended into on a `.env` search — the marker walk enumerates
            // everything because it must find `.sharibako` anywhere; this
            // walk only wants ordinary project directories. The named skip
            // list keeps it out of dependency/build forests the same way.
            guard !child.lastPathComponent.hasPrefix(".") else { continue }
            guard !skippedDirectoryNames.contains(child.lastPathComponent) else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else { continue }
            walk(child, depth: depth + 1, fileManager: fileManager, results: &results)
        }
    }
}
