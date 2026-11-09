import Foundation
import SharibakoCore

/// The age-key provider choice and the user-facing error sentences every
/// intent maps its failures through.
///
/// Moved out of `WorkshopModel.swift` unchanged (ho-06.10 AT-04) when the
/// verbs' state pushed that file past SwiftLint's `file_length` ceiling — a
/// mechanical split, the `Conduit`/`Conduit+Remote.swift` precedent.
extension WorkshopModel {
    /// Builds the age-key provider for decrypt operations (used from AT-02 on).
    ///
    /// The file provider wins when `SHARIBAKO_AGE_KEY` is set (the dev bypass,
    /// Decision 7); otherwise the GUI's own Keychain adapter (Decision 1).
    func makeAgeKeyProvider() -> any GUIAgeKeyProvider {
        if let devAgeKeyPath {
            return GUIFileAgeKeyProvider(path: devAgeKeyPath)
        }
        return GUIKeychainAgeKeyProvider()
    }

    /// Renders an error as a user-facing sentence.
    ///
    /// Dispatches to `vaultErrorMessage` for known `VaultError` cases;
    /// everything else falls through to a generic description.
    static func message(for error: Error) -> String {
        guard let vaultError = error as? VaultError else {
            return "Unexpected error: \(error)"
        }
        return Self.vaultErrorMessage(for: vaultError)
    }

    /// Names the `VaultError` cases the model can surface; split from
    /// `message(for:)` to keep cyclomatic complexity within the linter ceiling.
    private static func vaultErrorMessage(for vaultError: VaultError) -> String {
        switch vaultError {
        case .vaultNotFound(let path):
            return "No vault found at \(path.path)."
        case .yamlDecodeError(let path, _):
            return "Could not read \(path.lastPathComponent) — the file is not valid YAML."
        case .fileSystemError(let path, _):
            return "A filesystem operation failed at \(path.path)."
        case .secretNotFound(let scope, let key):
            return "Secret '\(key)' not found in scope '\(scope)'."
        case .scopeNotFound(let id):
            return "Scope '\(id)' not found."
        case .scopeAlreadyExists(let id):
            return "A scope named '\(id)' already exists."
        case .sharedEntryExists(let id):
            return "A shared entry named '\(id)' already exists."
        case .sharedEntryNotFound(let id):
            return "Shared entry '\(id)' not found."
        case .markerNotFound:
            return "No folder for this project was found under the scan folders."
        case .ageInvocationFailed(_, let stderr):
            return Self.ageFailureMessage(stderr: stderr)
        case .gitInvocationFailed(_, let stderr):
            return "Git error: \(stderr.prefix(120))"
        default:
            return "Vault error: \(vaultError)"
        }
    }

    /// The message for an `age` failure, by what `age` actually said.
    ///
    /// `age` is used for both directions, and the ho-06.9 gate showed a
    /// decrypt failure ("no identity matched any of the recipients") wearing an
    /// "Encryption failed" label. The recipient mismatch gets plain words — it
    /// means this vault's secrets were encrypted to a different key than the
    /// one in use, which is the one thing the user can act on.
    static func ageFailureMessage(stderr: String) -> String {
        let text = stderr.lowercased()
        if text.contains("no identity matched") {
            return "This key cannot read these secrets — they were encrypted to a different key than the one in use."
        }
        if text.contains("decrypt") || text.contains("identity") {
            return "Decryption failed: \(stderr.prefix(120))"
        }
        return "Encryption failed: \(stderr.prefix(120))"
    }
}
