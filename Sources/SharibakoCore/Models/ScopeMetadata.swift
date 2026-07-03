import Foundation

/// Contents of `vault/scopes/<id>/scope.yaml`.
///
/// Plaintext per-scope metadata. Fixed schema — see the system design's
/// Data Model section. New fields are added deliberately, not opportunistically.
public struct ScopeMetadata: Codable, Equatable, Sendable {
    /// Stable identifier for the scope.
    ///
    /// Matches the containing directory name (`scopes/<identity>/`).
    public let identity: String

    /// Category of the scope; drives grouping in the Workshop sidebar.
    public let type: ScopeType

    /// Optional human-friendly display label.
    ///
    /// Defaults to `identity` at read time on the surfaces when omitted.
    public let displayName: String?

    /// Coding keys map camelCase Swift properties to YAML snake_case.
    internal enum CodingKeys: String, CodingKey {
        case identity
        case type
        case displayName = "display_name"
    }

    /// Member-wise initializer used by tests and library callers building scopes in memory.
    public init(identity: String, type: ScopeType, displayName: String? = nil) {
        self.identity = identity
        self.type = type
        self.displayName = displayName
    }
}

/// Enumerated scope categories from the system design's Data Model.
///
/// Extension of this enum is deliberate: adding a case updates the Workshop
/// grouping and the CLI's `status` output.
public enum ScopeType: String, Codable, Equatable, Sendable {
    /// A project during development (working copy, dev secrets).
    case projectDev = "project-dev"
    /// A project's production surface (deployed secrets).
    case projectProd = "project-prod"
    /// A service (long-running, not project-shaped).
    case service
    /// A host or machine identity.
    case machine
    /// Anything else — deliberate escape hatch, discouraged in practice.
    case other
}
