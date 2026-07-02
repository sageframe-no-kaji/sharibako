import Foundation

/// Sharibako-specific exit code taxonomy.
///
/// Every failure exits with one of these codes so scripts can branch on the
/// category of error without parsing stderr. `0` means success; `1` is the
/// generic fallback when no more specific code applies.
enum SharibakoExitCode: Int32 {
    /// Successful completion.
    case success = 0
    /// Unspecified failure.
    case generic = 1
    /// Bad arguments, missing scope, unknown key, or other caller error.
    case userError = 2
    /// File-system or I/O error.
    case filesystem = 3
    /// `age` binary error or decryption failure.
    case age = 4
    /// `git` invocation error.
    case git = 5
    /// macOS Keychain or authentication error.
    case keychain = 6
}
