import ArgumentParser
import Foundation

/// Flags shared across every subcommand via `@OptionGroup`.
///
/// Each command declares `@OptionGroup var global: GlobalOptions` to expose
/// `--vault`, `--age-key`, `--json`, and `--verbose` at the command level.
struct GlobalOptions: ParsableArguments {
    /// Override the default vault directory (`~/.sharibako/vault/`).
    @Option(help: "Override the vault directory path.")
    var vault: String?

    /// Use a plaintext age key file instead of the macOS Keychain.
    ///
    /// Accepts any path resolvable by the shell. On macOS this bypasses Touch ID.
    /// Required on Linux.
    @Option(name: .customLong("age-key"), help: "Use this age key file instead of the Keychain.")
    var ageKey: String?

    /// Emit machine-readable JSON output on inspection verbs.
    @Flag(help: "Output in JSON format.")
    var json: Bool = false

    /// Enable verbose stderr logging.
    @Flag(name: .shortAndLong, help: "Enable verbose logging.")
    var verbose: Bool = false

    /// Resolves `--vault` to a `URL`, or `nil` when the flag was not supplied.
    var vaultURL: URL? { vault.map { URL(fileURLWithPath: $0) } }

    /// Resolves `--age-key` to a `URL`, or `nil` when the flag was not supplied.
    var ageKeyURL: URL? { ageKey.map { URL(fileURLWithPath: $0) } }
}
