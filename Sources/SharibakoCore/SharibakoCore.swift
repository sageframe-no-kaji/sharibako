// SharibakoCore: shared library for the Sharibako secrets vault.
//
// Owns the vault directory on disk, age invocation, schema, and link-graph
// resolution. Knows nothing about the user's filesystem outside the vault.
// Surfaced via the Sharibako (GUI) and SharibakoCLI (CLI) executables.

/// Namespace for the Sharibako vault library.
///
/// Holds the public API surface and shared utilities. Instantiation is
/// not supported (cases-less enum).
public enum SharibakoCore {
    /// Library version.
    ///
    /// Bumped at release tags. Surfaced by the CLI's `--version` flag
    /// and the Workshop's About pane.
    public static let version = "0.1.0"
}
