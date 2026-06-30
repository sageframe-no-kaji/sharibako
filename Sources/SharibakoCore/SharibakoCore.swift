// SharibakoCore: shared library for the Sharibako secrets vault.
//
// Owns the vault directory on disk, age invocation, schema, and link-graph
// resolution. Knows nothing about the user's filesystem outside the vault.
// Surfaced via the Sharibako (GUI) and SharibakoCLI (CLI) executables.

public enum SharibakoCore {
    public static let version = "0.1.0"
}
