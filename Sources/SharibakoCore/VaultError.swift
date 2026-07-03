import Foundation

/// The single error type surfaced from ``SharibakoCore`` public API.
///
/// Callers on the CLI and GUI switch over these cases to produce user-facing
/// messages without string-parsing an underlying `Error`. Cases are added
/// only when a genuinely new failure mode reaches the surface.
///
/// Cases: ``vaultNotFound(path:)``, ``scopeNotFound(id:)``,
/// ``secretNotFound(scope:key:)``, ``scopeAlreadyExists(id:)``,
/// ``sharedEntryNotFound(id:)``, ``linkTargetMissing(id:)``,
/// ``ageInvocationFailed(exitCode:stderr:)``, ``yamlEncodeError(path:underlying:)``,
/// ``yamlDecodeError(path:underlying:)``, ``fileSystemError(path:underlying:)``,
/// ``shellNotFound(name:)``, ``gitInvocationFailed(exitCode:stderr:)``,
/// ``markerNotFound(startingFrom:)``, ``markerMalformed(path:reason:)``,
/// ``envParseFailed(path:reason:)``, ``ingestKeyMismatch(unknownKey:)``,
/// ``ageIdentityNotConfigured``.
public enum VaultError: Error {
    /// The vault directory does not exist at the given path.
    case vaultNotFound(path: URL)
    /// No scope directory exists (or its `scope.yaml` is absent).
    case scopeNotFound(id: String)
    /// A secret was requested but no `.age` or `.link` file matches the key.
    case secretNotFound(scope: String, key: String)
    /// A scope creation collided with an existing scope of the same identity.
    case scopeAlreadyExists(id: String)
    /// A shared entry was expected in `shared/` but is not present.
    case sharedEntryNotFound(id: String)
    /// A `.link` file references a shared entry that no longer exists.
    case linkTargetMissing(id: String)
    /// The `age` binary was invoked and exited with a non-zero status.
    case ageInvocationFailed(exitCode: Int32, stderr: String)
    /// Encoding a value to YAML failed while writing the given path.
    case yamlEncodeError(path: URL, underlying: Error)
    /// Decoding YAML from disk failed for the given path.
    case yamlDecodeError(path: URL, underlying: Error)
    /// A filesystem operation failed for the given path.
    case fileSystemError(path: URL, underlying: Error)
    /// The named external binary could not be located on PATH.
    case shellNotFound(name: String)
    /// A `git` invocation exited non-zero.
    case gitInvocationFailed(exitCode: Int32, stderr: String)
    /// Scope resolution walked up from a starting directory without finding a `.sharibako` file.
    case markerNotFound(startingFrom: URL)
    /// A `.sharibako` file was found but its YAML could not be parsed or is missing required fields.
    case markerMalformed(path: URL, reason: String)
    /// A `.env`-style file could not be read or is fundamentally unusable (encoding failure, etc.).
    ///
    /// Distinct from parse warnings, which are collected in ``ParseWarning`` and returned to
    /// callers without throwing.
    case envParseFailed(path: URL, reason: String)
    /// A ``KeyDecision`` passed to `acceptIngest` names a key absent from the proposal.
    case ingestKeyMismatch(unknownKey: String)
    /// An encrypt/decrypt operation was attempted on a ``VaultCore`` bound
    /// without an age identity (no key URL / public key configured).
    case ageIdentityNotConfigured
}

/// Stand-in for a decoder error whose description may embed decrypted secret
/// material.
///
/// Yams errors carry the source YAML text and problem-mark context; on the
/// decrypt path that source IS the secret. Surfaces print
/// `underlying.localizedDescription` when rendering ``VaultError/yamlDecodeError(path:underlying:)``,
/// so this type guarantees the rendered string never contains payload bytes —
/// only the original error's type name survives for diagnosis.
internal struct RedactedDecodeError: Error, CustomStringConvertible, LocalizedError {
    /// Type name of the error being redacted (e.g. `YamlError`).
    internal let originalErrorType: String

    internal var description: String {
        "decode failed (\(originalErrorType)); details redacted — the payload is secret material"
    }

    internal var errorDescription: String? { description }
}
