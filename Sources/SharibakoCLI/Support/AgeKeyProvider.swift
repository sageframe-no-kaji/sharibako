import Foundation

/// A handle wrapping the URL of an age identity file for the duration of one operation.
///
/// Call `release()` when the operation completes. `KeychainAgeKeyProvider` uses
/// the cleanup closure to scrub and delete the temp file; `FileAgeKeyProvider`'s
/// cleanup is a no-op.
struct AgeKeyHandle: Sendable {
    /// Absolute URL of the age private-key file the caller passes to `age --identity`.
    let url: URL

    private let cleanup: @Sendable () -> Void

    /// Creates a handle with the given URL and cleanup action.
    init(url: URL, cleanup: @escaping @Sendable () -> Void) {
        self.url = url
        self.cleanup = cleanup
    }

    /// Runs the cleanup closure.
    ///
    /// For `KeychainAgeKeyProvider` this scrubs and removes the temp file.
    /// For `FileAgeKeyProvider` this is a no-op.
    func release() { cleanup() }
}

/// Provides an age identity file for the duration of one vault operation.
///
/// Two concrete implementations exist:
/// - `FileAgeKeyProvider` — reads a plaintext identity file; used on Linux and in tests.
/// - `KeychainAgeKeyProvider` — retrieves from the macOS Keychain with Touch ID; macOS only.
protocol AgeKeyProvider: Sendable {
    /// Returns a handle whose `url` points at an age identity file.
    ///
    /// `reason` is surfaced as the Touch ID prompt string on macOS; ignored by
    /// `FileAgeKeyProvider`.
    ///
    /// - Parameter reason: Human-readable description of why the key is needed.
    /// - Returns: An `AgeKeyHandle` whose `release()` must be called after use.
    /// - Throws: `CLIError.ageKeyFileNotFound` if the key file does not exist;
    ///   platform-specific errors for Keychain access failures.
    func loadIdentity(reason: String) throws -> AgeKeyHandle
}

/// Hands the caller a pre-existing age key file directly.
///
/// The file is never copied or deleted — `release()` is a no-op. Used on Linux,
/// in tests, and when the user supplies `--age-key <path>` to bypass the Keychain.
struct FileAgeKeyProvider: AgeKeyProvider {
    /// Absolute URL of the age private-key file.
    let path: URL

    func loadIdentity(reason: String) throws -> AgeKeyHandle {
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw CLIError.ageKeyFileNotFound(path: path)
        }
        return AgeKeyHandle(url: path) {}
    }
}

/// CLI-specific errors that fall outside the `VaultError` domain.
enum CLIError: Error {
    /// The age key file at the given path does not exist.
    case ageKeyFileNotFound(path: URL)
    /// The Keychain operation returned an unexpected OSStatus.
    case keychainStoreFailed(osStatus: Int32)
    /// Failed to retrieve the age key from the Keychain.
    case keychainLoadFailed(osStatus: Int32)
    /// The supplied file is not a valid age identity.
    case invalidAgeKeyFile(path: URL)
    /// A key already exists and `--force` was not supplied.
    case ageKeyAlreadyExists
    /// `key export --private` was used without `--i-know-this-is-plaintext`.
    case exportRequiresPlaintextAcknowledgement
    /// The age key file has no `# public key:` header line.
    case publicKeyHeaderMissing
}
