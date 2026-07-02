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
            let payload = "{\"error\": \"\(errorReport.message)\", \"code\": \(errorReport.code.rawValue)}"
            fputs(payload + "\n", stderr)
        } else {
            fputs("Error: \(errorReport.message)\n", stderr)
            if let fix = errorReport.remediation {
                fputs("Hint:  \(fix)\n", stderr)
            }
        }
        exit(errorReport.code.rawValue)
    }

    // MARK: - Private mapping

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
        // swiftlint:disable:next pattern_matching_keywords
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
        // swiftlint:disable:next pattern_matching_keywords
        case .ageInvocationFailed(let exitCode, let stderrText):
            return ErrorReport(
                code: .age,
                message: "age binary failed (exit \(exitCode)): \(stderrText.isEmpty ? "(no output)" : stderrText)",
                remediation: "Verify `age` is installed and on PATH."
            )
        // swiftlint:disable:next pattern_matching_keywords
        case .yamlEncodeError(let path, let underlying):
            return ErrorReport(
                code: .filesystem,
                message: "Failed to encode YAML at \(path.path): \(underlying.localizedDescription)",
                remediation: nil
            )
        // swiftlint:disable:next pattern_matching_keywords
        case .yamlDecodeError(let path, let underlying):
            return ErrorReport(
                code: .filesystem,
                message: "Failed to decode YAML at \(path.path): \(underlying.localizedDescription)",
                remediation: nil
            )
        // swiftlint:disable:next pattern_matching_keywords
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
        // swiftlint:disable:next pattern_matching_keywords
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
        // swiftlint:disable:next pattern_matching_keywords
        case .markerMalformed(let path, let reason):
            return ErrorReport(
                code: .userError,
                message: "Malformed marker at \(path.path): \(reason).",
                remediation: nil
            )
        // swiftlint:disable:next pattern_matching_keywords
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
        }
    }

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
            return ErrorReport(
                code: .keychain,
                message: "Failed to retrieve age key from Keychain (OSStatus \(osStatus)).",
                remediation: "Run `sharibako key generate` to create a new key."
            )
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
        // swiftlint:disable:next pattern_matching_keywords
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
        }
    }
}
