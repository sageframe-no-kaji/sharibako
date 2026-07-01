import Foundation

/// The single error type surfaced from ``SharibakoCore`` public API.
///
/// Callers on the CLI and GUI switch over these cases to produce user-facing
/// messages without string-parsing an underlying `Error`. Cases are added
/// only when a genuinely new failure mode reaches the surface.
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
}
