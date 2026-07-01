import Foundation

/// Non-decrypting description of a single secret slot in a scope.
///
/// Returned by `VaultCore.inspect` so callers can enumerate a scope's keys
/// and their link/value status without invoking `age`.
public struct SecretInfo: Equatable, Sendable {
    /// The secret's key (the filename stem before `.age` or `.link`).
    public let key: String
    /// Whether the slot holds a direct value or a link to a shared entry.
    public let kind: Kind

    /// Discriminates a direct encrypted value from a link to a shared entry.
    public enum Kind: Equatable, Sendable {
        /// A `<KEY>.age` file — value encrypted in place.
        case value
        /// A `<KEY>.link` file pointing at `shared/<sharedID>.age`.
        case link(sharedID: String)
    }

    /// Member-wise initializer used by `VaultCore.inspect` and tests.
    public init(key: String, kind: Kind) {
        self.key = key
        self.kind = kind
    }
}
