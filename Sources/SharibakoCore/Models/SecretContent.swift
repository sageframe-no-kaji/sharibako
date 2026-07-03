import Foundation

/// Decrypted payload of a `<KEY>.age` or `shared/<id>.age` file.
///
/// Fixed schema from the system design's Data Model: a value plus optional
/// human notes and an ISO 8601 rotation date. The v1 shape is deliberately
/// narrow; adding fields (e.g. a password-manager-style `login`) is called
/// out as a scope boundary in the system design.
public struct SecretContent: Codable, Equatable, Sendable {
    /// The secret string itself — the value the surfaces materialize into `.env`.
    public let value: String

    /// Optional free-form notes: origin, purpose, escalation contact.
    public let notes: String?

    /// ISO 8601 date the value was last rotated (`YYYY-MM-DD`).
    ///
    /// Stored as a plain `String` in v1; no `Date` conversion happens inside the vault.
    public let rotatedAt: String?

    /// Coding keys map camelCase Swift properties to YAML snake_case.
    internal enum CodingKeys: String, CodingKey {
        case value
        case notes
        case rotatedAt = "rotated_at"
    }

    /// Member-wise initializer used by encryption operations and tests.
    public init(value: String, notes: String? = nil, rotatedAt: String? = nil) {
        self.value = value
        self.notes = notes
        self.rotatedAt = rotatedAt
    }
}
