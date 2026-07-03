import Foundation
import SharibakoCore

/// A structured description of a CLI failure, produced by `ErrorReporter.makeReport(for:)`.
struct ErrorReport {
    /// Numeric exit code for scripts.
    let code: SharibakoExitCode

    /// Short, human-readable description of what went wrong.
    let message: String

    /// Suggested remediation step, if one exists.
    let remediation: String?
}

/// Maps `VaultError` and `CLIError` to structured exit codes and messages.
///
/// The `report(_:json:)` method is the production `-> Never` surface. The
/// `makeReport(for:)` method is the testable seam.
enum ErrorReporter {
    /// Builds an `ErrorReport` for any `Error`.
    ///
    /// All `VaultError` and `CLIError` cases map to specific codes. Unknown error
    /// types fall back to `.generic` with the error's `localizedDescription`.
    static func makeReport(for error: Error) -> ErrorReport {
        switch error {
        case let vaultErr as VaultError:
            return report(vaultError: vaultErr)
        case let cliErr as CLIError:
            return report(cliError: cliErr)
        default:
            return ErrorReport(
                code: .generic,
                message: error.localizedDescription,
                remediation: nil
            )
        }
    }

    /// Prints the error to stderr and exits with the taxonomy code.
    ///
    /// When `json` is true, emits `{"error": "...", "code": N}` to stderr.
    static func report(_ error: Error, json: Bool) -> Never {
        let errorReport = makeReport(for: error)
        if json {
            fputs(jsonPayload(for: errorReport) + "\n", stderr)
        } else {
            fputs("Error: \(errorReport.message)\n", stderr)
            if let fix = errorReport.remediation {
                fputs("Hint:  \(fix)\n", stderr)
            }
        }
        exit(errorReport.code.rawValue)
    }

    /// Encodes an `ErrorReport` as a single-line JSON object.
    ///
    /// Uses `JSONEncoder` so messages containing quotes, backslashes, or
    /// newlines (git/age stderr passes through verbatim) stay valid JSON —
    /// string interpolation did not escape them.
    static func jsonPayload(for errorReport: ErrorReport) -> String {
        struct Payload: Encodable {
            let error: String
            let code: Int32
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = Payload(error: errorReport.message, code: errorReport.code.rawValue)
        guard let data = try? encoder.encode(payload),
            let rendered = String(bytes: data, encoding: .utf8)
        else {
            // Encodable String/Int32 cannot realistically fail to encode; keep
            // a valid-JSON fallback rather than crashing the error path.
            return "{\"error\":\"(unrenderable error message)\",\"code\":\(errorReport.code.rawValue)}"
        }
        return rendered
    }

    // MARK: - Private mapping

    // Exhaustive error-mapping switch: one case per VaultError; length and branching mirror the enum.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private static func report(vaultError: VaultError) -> ErrorReport {
        switch vaultError {
        case .vaultNotFound(let path):
            return ErrorReport(
                code: .filesystem,
                message: "Vault not found at \(path.path).",
                remediation: "Run `sharibako key generate` to create one."
            )
        case .scopeNotFound(let id):
            return ErrorReport(
                code: .userError,
                message: "Scope \"\(id)\" does not exist.",
                remediation: nil
            )
        case .secretNotFound(let scope, let key):
            return ErrorReport(
                code: .userError,
                message: "Key \"\(key)\" not found in scope \"\(scope)\".",
                remediation: nil
            )
        case .scopeAlreadyExists(let id):
            return ErrorReport(
                code: .userError,
                message: "Scope \"\(id)\" already exists.",
                remediation: nil
            )
        case .sharedEntryNotFound(let id):
            return ErrorReport(
                code: .userError,
                message: "Shared entry \"\(id)\" does not exist.",
                remediation: nil
            )
        case .linkTargetMissing(let id):
            return ErrorReport(
                code: .userError,
                message: "Link target \"\(id)\" is missing from the shared directory.",
                remediation: "Run `sharibako list --shared` to see available shared entries."
            )
        case .ageInvocationFailed(let exitCode, let stderrText):
            return ErrorReport(
                code: .age,
                message: "age binary failed (exit \(exitCode)): \(stderrText.isEmpty ? "(no output)" : stderrText)",
                remediation: "Verify `age` is installed and on PATH."
            )
        case .yamlEncodeError(let path, let underlying):
            return ErrorReport(
                code: .filesystem,
                message: "Failed to encode YAML at \(path.path): \(underlying.localizedDescription)",
                remediation: nil
            )
        case .yamlDecodeError(let path, let underlying):
            return ErrorReport(
                code: .filesystem,
                message: "Failed to decode YAML at \(path.path): \(underlying.localizedDescription)",
                remediation: nil
            )
        case .fileSystemError(let path, let underlying):
            return ErrorReport(
                code: .filesystem,
                message: "File system error at \(path.path): \(underlying.localizedDescription)",
                remediation: nil
            )
        case .shellNotFound(let name):
            let code: SharibakoExitCode = name == "git" ? .git : .age
            return ErrorReport(
                code: code,
                message: "The `\(name)` binary was not found on PATH.",
                remediation: "Install `\(name)` (e.g. `brew install \(name == "git" ? "git" : "age")`)."
            )
        case .gitInvocationFailed(let exitCode, let stderrText):
            return ErrorReport(
                code: .git,
                message: "git failed (exit \(exitCode)): \(stderrText.isEmpty ? "(no output)" : stderrText)",
                remediation: nil
            )
        case .markerNotFound(let startingFrom):
            return ErrorReport(
                code: .userError,
                message: "No `.sharibako` marker found starting from \(startingFrom.path).",
                remediation: "Run `sharibako init` in your project directory to create one."
            )
        case .markerMalformed(let path, let reason):
            return ErrorReport(
                code: .userError,
                message: "Malformed marker at \(path.path): \(reason).",
                remediation: nil
            )
        case .envParseFailed(let path, let reason):
            return ErrorReport(
                code: .filesystem,
                message: "Cannot parse env file at \(path.path): \(reason).",
                remediation: nil
            )
        case .ingestKeyMismatch(let unknownKey):
            return ErrorReport(
                code: .userError,
                message: "Ingest decision references unknown key \"\(unknownKey)\".",
                remediation: nil
            )
        case .ageIdentityNotConfigured:
            return ErrorReport(
                code: .age,
                message: "No age identity is configured for this vault handle.",
                remediation:
                    "Pass --age-key <path>, set SHARIBAKO_AGE_KEY, or run `sharibako key generate`."
            )
        case .invalidIdentifier(let kind, let value, let source):
            let origin = source.map { " (read from \($0.path))" } ?? ""
            return ErrorReport(
                code: .userError,
                message: "Invalid \(kind.rawValue) \"\(value)\"\(origin).",
                remediation:
                    "Identifiers must start with a letter, digit, or underscore and contain "
                    + "only letters, digits, and ._- (no path separators)."
            )
        case .remoteURLRejected(let url, let reason):
            return ErrorReport(
                code: .userError,
                message: "Remote URL \"\(url)\" rejected: \(reason).",
                remediation: "Use an https://, ssh://, scp-style user@host:path, or local-path remote."
            )
        }
    }

    // Exhaustive error-mapping switch: one case per CLIError; length and branching mirror the enum.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func report(cliError: CLIError) -> ErrorReport {
        switch cliError {
        case .ageKeyFileNotFound(let path):
            return ErrorReport(
                code: .filesystem,
                message: "Age key file not found at \(path.path).",
                remediation: "Run `sharibako key generate` or supply a valid `--age-key` path."
            )
        case .keychainStoreFailed(let osStatus):
            return ErrorReport(
                code: .keychain,
                message: "Failed to store age key in Keychain (OSStatus \(osStatus)).",
                remediation: nil
            )
        case .keychainLoadFailed(let osStatus):
            // Branch on the OSStatus so the remediation matches the cause —
            // advising `key generate` to a user who merely cancelled Touch ID
            // points them at the command that (with --force) destroys vault
            // access. Numeric literals keep this file buildable on Linux,
            // where the Security framework is unavailable.
            switch osStatus {
            case -25300:  // errSecItemNotFound
                return ErrorReport(
                    code: .keychain,
                    message: "No age key found in the Keychain.",
                    remediation:
                        "Run `sharibako key generate` to create one, or `sharibako key import` to store an existing key."
                )
            case -128:  // errSecUserCanceled
                return ErrorReport(
                    code: .keychain,
                    message: "The Touch ID / password prompt was cancelled.",
                    remediation: "Re-run the command and approve the prompt."
                )
            default:
                return ErrorReport(
                    code: .keychain,
                    message: "Failed to retrieve age key from Keychain (OSStatus \(osStatus)).",
                    remediation: "Decode the status with `security error \(osStatus)`."
                )
            }
        case .invalidAgeKeyFile(let path):
            return ErrorReport(
                code: .userError,
                message: "The file at \(path.path) does not look like an age identity.",
                remediation: "Supply an age private-key file beginning with `AGE-SECRET-KEY-`."
            )
        case .ageKeyAlreadyExists:
            return ErrorReport(
                code: .userError,
                message: "An age key already exists.",
                remediation: "Use `--force` to overwrite."
            )
        case .exportRequiresPlaintextAcknowledgement:
            return ErrorReport(
                code: .userError,
                message: "`--private` requires `--i-know-this-is-plaintext` to acknowledge the risk.",
                remediation: "Use: sharibako key export --private --i-know-this-is-plaintext"
            )
        case .publicKeyHeaderMissing:
            return ErrorReport(
                code: .age,
                message: "The age key file has no `# public key:` header line.",
                remediation: "Regenerate the key with `age-keygen`."
            )
        case .valueInputConflict:
            return ErrorReport(
                code: .userError,
                message: "Supply exactly one of --value or --from-stdin, not both.",
                remediation: nil
            )
        case .valueInputRequired:
            return ErrorReport(
                code: .userError,
                message: "Supply a value via --value <v> or --from-stdin.",
                remediation: nil
            )
        case .secretAlreadyExists(let scope, let key):
            return ErrorReport(
                code: .userError,
                message: "'\(key)' already exists in '\(scope)'. Use `sharibako rotate` to change its value.",
                remediation: "Use --force to overwrite."
            )
        case .materializeDiffPending:
            return ErrorReport(
                code: .userError,
                message: "Drift detected (detail above). Use --force to overwrite.",
                remediation: nil
            )
        case .updateFileMissing:
            return ErrorReport(
                code: .userError,
                message: "No target file to read. Run `sharibako materialize` first.",
                remediation: nil
            )
        case .syncRejected:
            return ErrorReport(
                code: .git,
                message: "Push rejected by remote (detail above).",
                remediation: nil
            )
        case .syncConflict:
            return ErrorReport(
                code: .git,
                message: "Pull conflict (detail above). Resolve manually, then run `sharibako sync` again.",
                remediation: nil
            )
        case .notInteractiveTerminal:
            return ErrorReport(
                code: .userError,
                message: "`init` needs an interactive terminal; scriptable flags are a followup.",
                remediation: nil
            )
        case .aborted:
            return ErrorReport(
                code: .success,
                message: "Aborted.",
                remediation: nil
            )
        case .nothingToInitialize(let directory):
            return ErrorReport(
                code: .userError,
                message: "No secrets found in \(directory.path). Nothing to initialize.",
                remediation: "Add a `.env` with at least one KEY=value, or `sharibako add` to an existing scope."
            )
        case .runCommandEmpty:
            return ErrorReport(
                code: .userError,
                message: "No command to run. Usage: `sharibako run [--scope <id>] -- <command> [args...]`.",
                remediation: "Supply a command after `--`, or use `--dry-run` to list what would be injected."
            )
        case .runSpawnFailed(let command, let underlying):
            return ErrorReport(
                code: .generic,
                message: "Failed to run \"\(command)\": \(underlying)",
                remediation: "Verify the command exists and is on your PATH."
            )
        }
    }
}
