import Foundation
import SharibakoCore

/// Resolves a scope identifier for the Materializer-triad verbs (materialize, update, clean, heal).
///
/// Returns the scope ID and — when scope was discovered via cwd walk — the already-loaded
/// marker. When the scope was supplied explicitly, the marker is `nil` and the caller must
/// resolve it via `Materializer.resolveMarker(forScope:scanRoots:)`.
enum ScopeResolver {
    /// Resolves scope from an explicit argument or by walking up from `startingFrom`.
    ///
    /// - Parameters:
    ///   - explicit: Scope identifier supplied directly by the user, or `nil` to trigger
    ///     cwd-based marker discovery (git-style walk-up).
    ///   - startingFrom: Directory to walk up from when `explicit` is `nil`.
    ///   - materializer: Used to invoke `resolveMarker(startingFrom:)` on the walk path.
    /// - Returns: A tuple of the resolved scope ID and the marker, if the marker was
    ///   resolved as part of the cwd walk. When `explicit` was non-`nil`, `marker` is `nil`.
    /// - Throws: `VaultError.markerNotFound` if `explicit` is `nil` and no `.sharibako`
    ///   is found walking up from `startingFrom`.
    static func resolve(
        explicit: String?,
        startingFrom: URL,
        materializer: Materializer
    ) throws -> (scopeID: String, marker: ScopeMarker?) {
        if let scopeID = explicit {
            return (scopeID, nil)
        }
        let marker = try materializer.resolveMarker(startingFrom: startingFrom)
        return (marker.scope, marker)
    }
}
