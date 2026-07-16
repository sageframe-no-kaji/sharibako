import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

// MARK: - Encryption fixture for App tests

/// Generates an ephemeral age key pair for a single test block, tears it down after.
///
/// Mirrors `AgeKeyFixture` from the Core test suite without importing
/// across module boundaries.
enum AppAgeKeyFixture {
    struct Fixture {
        let privateKeyURL: URL
        let publicKey: String
    }

    static func generate() throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharibako-appkey-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keyURL = dir.appendingPathComponent("age-key.txt")
        let ageKeygen = try Shell.findExecutable("age-keygen")
        let result = try Shell.run(ageKeygen, ["-o", keyURL.path])
        guard result.exitCode == 0 else {
            throw VaultError.ageInvocationFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        let contents = try String(contentsOf: keyURL, encoding: .utf8)
        let prefix = "# public key: "
        var publicKey: String?
        for line in contents.split(whereSeparator: \.isNewline) where line.hasPrefix(prefix) {
            publicKey = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        guard let publicKey else {
            throw VaultError.ageInvocationFailed(
                exitCode: -1, stderr: "no '# public key:' header in generated key file")
        }
        return Fixture(privateKeyURL: keyURL, publicKey: publicKey)
    }

    static func withEphemeralKey(_ body: (Fixture) throws -> Void) throws {
        let fixture = try generate()
        defer { try? FileManager.default.removeItem(at: fixture.privateKeyURL.deletingLastPathComponent()) }
        try body(fixture)
    }

    /// Async overload for tests that `await` async intents (ho-06.1).
    ///
    /// The compiler selects this in an async context and the synchronous one
    /// otherwise, so existing synchronous tests are untouched.
    static func withEphemeralKey(_ body: @MainActor (Fixture) async throws -> Void) async throws {
        let fixture = try generate()
        defer {
            try? FileManager.default.removeItem(
                at: fixture.privateKeyURL.deletingLastPathComponent())
        }
        try await body(fixture)
    }
}

// MARK: - Fake Keychain store for first-run wizard tests (ho-06.3)

/// A `GUIKeychainStore` fake that never touches the real Keychain.
///
/// `GUIAgeKeyBootstrap`'s injected seam (ho-06.3 Decision 5, Do Not §4).
/// Tracks the last stored bytes and lets tests preset `itemExists()`'s
/// answer or force either method to throw, so `WorkshopModel+FirstRun.swift`'s
/// branching (existing-key short-circuit, store-failure error mapping) is
/// exercised without an entitlement.
final class FakeKeychainStore: GUIKeychainStore {
    /// The bytes passed to the last `storeIdentity` call, or `nil` if none.
    private(set) var storedContents: Data?

    /// The value `itemExists()` returns when `existsError` is `nil`.
    var existsResult = false

    /// When set, `itemExists()` throws this instead of returning `existsResult`.
    var existsError: Error?

    /// When set, `storeIdentity(_:)` throws this instead of recording.
    var storeError: Error?

    func storeIdentity(_ contents: Data) throws {
        if let storeError {
            throw storeError
        }
        storedContents = contents
    }

    func itemExists() throws -> Bool {
        if let existsError {
            throw existsError
        }
        return existsResult
    }
}

/// Shared fixtures for the first-run wizard's split test files
/// (`WorkshopModelFirstRunTests.swift`,
/// `WorkshopModelFirstRunBackupRootTests.swift`,
/// `WorkshopModelFirstRunCompletionTests.swift`) — one definition instead of
/// three copies, and it keeps each suite's own body under SwiftLint's
/// `type_body_length` ceiling.
@MainActor
enum FirstRunTestSupport {
    /// A `.noVault` model over a fresh temp `home`, with the vault resolved
    /// to `<home>/vault` (never created by this helper).
    static func noVaultModel(home: URL, environmentExtra: [String: String] = [:]) -> WorkshopModel {
        var environment = ["SHARIBAKO_VAULT": home.appendingPathComponent("vault").path]
        environment.merge(environmentExtra) { _, new in new }
        return WorkshopModel(environment: environment, home: home)
    }

    /// Strips any trailing `/` from `url.path`.
    ///
    /// `URL(fileURLWithPath:)`/`appendingPathComponent(_:)` stat the
    /// filesystem on Apple platforms and append a trailing slash once the
    /// target directory actually exists — so a URL captured *before* a
    /// directory is created and the "same" URL reconstructed *after* it
    /// exists can differ by a trailing slash even though they name the same
    /// path. Comparisons in the first-run tests normalize through this
    /// rather than relying on raw `URL` equality.
    static func normalizedPath(_ url: URL) -> String {
        var path = url.path
        if path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}

// MARK: - Vault+Git helper for sync tests

/// Materialises a temp vault with a git repo, an identity, and a bare remote.
///
/// Returns the vault URL and the bare remote path so sync tests can verify push no-ops.
func withGitVaultAndBareRemote(
    _ body: @MainActor (URL, URL) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("sharibako-synctest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let vaultURL = root.appendingPathComponent("vault")
    let remoteURL = root.appendingPathComponent("remote.git")

    // 1. Create the bare remote.
    let git = try Shell.findExecutable("git")
    let bareResult = try Shell.run(
        git, ["init", "--bare", "--initial-branch=main", remoteURL.path])
    guard bareResult.exitCode == 0 else {
        throw VaultError.gitInvocationFailed(
            exitCode: bareResult.exitCode, stderr: bareResult.stderr)
    }

    // 2. Set up the vault.
    try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
    try VaultLayout.createVaultLayout(at: vaultURL)
    let conduit = try Conduit(vaultURL: vaultURL)
    try conduit.initializeRepository()
    _ = try Shell.run(git, ["checkout", "-b", "main"], workingDirectory: vaultURL)
    try conduit.setIdentity(name: "App Tests", email: "apptests@example.invalid")
    try conduit.setRemote(remoteURL.path)

    // Initial commit so there's a branch to push.
    let placeholder = vaultURL.appendingPathComponent(".gitkeep")
    try "".write(to: placeholder, atomically: true, encoding: .utf8)
    _ = try conduit.commit(message: "Initial vault setup")

    try await body(vaultURL, remoteURL)
}
