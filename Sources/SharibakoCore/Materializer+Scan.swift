import Foundation

/// Scan and status operations for ``Materializer`` — the survey side of the
/// bridge: walking scan roots for `.sharibako` markers and reporting where a
/// scope lives.
///
/// Kept in an extension file matching the ingest split: the type declaration
/// and marker load/write/materialize/clean/heal live in `Materializer.swift`;
/// the ingest/update work in `Materializer+Ingest.swift`; the walk lives here.
extension Materializer {
    /// Walks `roots` recursively and returns every `.sharibako` marker found,
    /// plus the ones that failed to load.
    ///
    /// Results are ordered breadth-first from each root, alphabetical within a depth,
    /// deduplicated by absolute path when roots overlap. A marker that fails to
    /// load — malformed YAML, an out-of-grammar scope, a hostile
    /// `materialize_to` — is skipped and reported in ``ScanReport/failures``
    /// rather than aborting the walk (ho-04.11): scan roots contain other
    /// people's repositories, and surveying past a bad marker is not the same
    /// as acting on one (`loadMarker` still throws for direct callers).
    public func scan(roots: [URL]) throws -> ScanReport {
        let fileManager = FileManager.default
        var seen = Set<String>()
        var markers: [ScopeMarker] = []
        var failures: [ScanFailure] = []
        for root in roots {
            guard fileManager.fileExists(atPath: root.path) else { continue }
            let markerURLs = enumerateMarkerFiles(under: root)
            for url in markerURLs {
                let standardized = url.standardizedFileURL.path
                if seen.contains(standardized) { continue }
                seen.insert(standardized)
                do {
                    markers.append(try loadMarker(at: url))
                } catch let error as VaultError {
                    failures.append(ScanFailure(markerURL: url, reason: failureReason(error)))
                }
            }
        }
        return ScanReport(markers: markers, failures: failures)
    }

    /// Extracts the human-readable core of a marker load failure.
    private func failureReason(_ error: VaultError) -> String {
        switch error {
        case .markerMalformed(_, let reason):
            return reason
        case .invalidIdentifier(let kind, let value, _):
            return "invalid \(kind.rawValue): \"\(value)\""
        default:
            return "\(error)"
        }
    }

    /// Reports where the scope lives from this machine's perspective.
    ///
    /// - Throws: ``VaultError/scopeNotFound(id:)`` if neither the vault nor any marker
    ///   knows about the scope; other `VaultError` cases for underlying failures.
    public func status(scopeID: String, scanRoots: [URL]) throws -> ScopeState {
        let allScopes = try vaultCore.listScopes()
        let hasScope = allScopes.contains { $0.identity == scopeID }
        let markers = try scan(roots: scanRoots).markers
        let matchingMarker = markers.first { $0.scope == scopeID }
        if hasScope {
            if let marker = matchingMarker {
                return .liveHere(markerURL: marker.markerURL, targetURL: marker.targetURL)
            }
            return .liveElsewhere
        }
        if let marker = matchingMarker {
            return .orphaned(
                markerURL: marker.markerURL,
                reason: "vault has no scope named '\(scopeID)'"
            )
        }
        throw VaultError.scopeNotFound(id: scopeID)
    }

    /// Recursive enumeration of `.sharibako` regular files below `root`, ordered
    /// breadth-first / alphabetical.
    private func enumerateMarkerFiles(under root: URL) -> [URL] {
        let fileManager = FileManager.default
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: []
            )
        else {
            return []
        }
        var found: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == ".sharibako" {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                found.append(url)
            }
        }
        found.sort { lhs, rhs in
            let lhsDepth = lhs.pathComponents.count
            let rhsDepth = rhs.pathComponents.count
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            return lhs.path < rhs.path
        }
        return found
    }
}
