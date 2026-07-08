import ArgumentParser
import Foundation
import SharibakoCore

/// Parent command grouping `key generate`, `key import`, and `key export`.
struct KeyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "key",
        abstract: "Manage the age identity key.",
        subcommands: [
            GenerateCommand.self,
            ImportCommand.self,
            ExportCommand.self,
        ]
    )
}

// MARK: - key generate

/// Generates a fresh age key pair and stores the private key.
///
/// On macOS (without `--age-key`): stores in the Keychain with Touch ID gating.
/// With `--age-key <path>`: writes the plaintext private key to the given file.
struct GenerateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate",
        abstract: "Generate a new age key pair."
    )

    @OptionGroup var global: GlobalOptions

    /// Overwrite an existing key when present.
    @Flag(help: "Replace an existing age key (generate otherwise refuses).")
    var force: Bool = false

    /// Skip the interactive confirmation prompt when `--force` is used.
    @Flag(help: "Skip the replacement confirmation prompt.")
    var yes: Bool = false

    func run() async throws {
        do { try _run() } catch { ErrorReporter.report(error, json: global.json) }
    }

    // MARK: - Internal for testing

    // _run: leading-underscore testable-entry-point convention (.swift-format NoLeadingUnderscores: false).
    // swiftlint:disable:next identifier_name
    func _run() throws {
        // Scaffold the vault directory first. `key generate` is the command the
        // "vault not found" hint names as the way to create a vault, and every
        // other verb requires the vault to already exist — without this, a fresh
        // install is a catch-22 (ho-04.14). Idempotent: a no-op on an existing vault.
        let vaultURL = VaultLocator.intendedVaultURL(globalFlag: global.vaultURL)
        try VaultCore.createVault(at: vaultURL)

        let destPath = VaultLocator.resolveAgeKey(globalFlag: global.ageKeyURL)

        if let path = destPath {
            try generateToFile(at: path)
        } else {
            #if os(macOS)
                try generateToKeychain()
            #else
                let defaultPath = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".config")
                    .appendingPathComponent("sharibako")
                    .appendingPathComponent("age-key")
                try generateToFile(at: defaultPath)
            #endif
        }
    }

    // MARK: - File path

    /// Generates a key file at `path`, prompting before overwrite under `--force` without `--yes`.
    ///
    /// `lineReader` is the injected prompt-answer seam (defaults to stdin) so tests
    /// can drive the overwrite confirmation without a terminal.
    func generateToFile(at path: URL, lineReader: () -> String? = { readLine() }) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: path.path) {
            guard force else { throw CLIError.ageKeyAlreadyExists }
            if !yes {
                fputs("Overwrite existing age key at \(path.path)? [y/N] ", stderr)
                let answer = lineReader() ?? ""
                guard answer.lowercased().hasPrefix("y") else {
                    fputs("Aborted.\n", stderr)
                    return
                }
            }
        }
        // Generate to a staging path, then swap into place: if age-keygen is
        // missing or fails, the existing key — the only thing that decrypts
        // the vault — must survive. (Deleting first also matters mechanically:
        // age-keygen refuses to write over an existing file.)
        let staging = path.deletingLastPathComponent()
            .appendingPathComponent(".sharibako-keygen-\(UUID().uuidString)")
        let publicKey: String
        do {
            publicKey = try AgeKeyBootstrap.generateToFile(at: staging)
            if fileManager.fileExists(atPath: path.path) {
                _ = try fileManager.replaceItemAt(path, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: path)
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        fputs("Save this recipient key somewhere safe:\n", stderr)
        print(publicKey)
    }

    // MARK: - Keychain path (macOS only)

    #if os(macOS)
        private func generateToKeychain() throws {
            let keychain = KeychainAgeKeyProvider()
            if try keychain.itemExists() {
                guard force else { throw CLIError.ageKeyAlreadyExists }
                if !yes {
                    fputs("Overwrite existing age key in Keychain? [y/N] ", stderr)
                    let answer = readLine() ?? ""
                    guard answer.lowercased().hasPrefix("y") else {
                        fputs("Aborted.\n", stderr)
                        return
                    }
                }
            }
            let publicKey = try AgeKeyBootstrap.generateToKeychain()
            fputs("Save this recipient key somewhere safe:\n", stderr)
            print(publicKey)
        }
    #endif
}

// MARK: - key import

/// Imports an existing age key file into Keychain (macOS) or the default file location.
struct ImportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import an existing age key file."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Path to the age private-key file to import.")
    var sourcePath: String

    @Flag(name: .customLong("delete-source"), help: "Delete the source file after import.")
    var deleteSource: Bool = false

    @Flag(name: .customLong("keep-source"), help: "Keep the source file (skip deletion prompt).")
    var keepSource: Bool = false

    func run() async throws {
        do { try _run() } catch { ErrorReporter.report(error, json: global.json) }
    }

    // MARK: - Internal for testing

    // _run: leading-underscore testable-entry-point convention (.swift-format NoLeadingUnderscores: false).
    // swiftlint:disable:next identifier_name
    func _run() throws {
        let sourceURL = URL(fileURLWithPath: sourcePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw CLIError.ageKeyFileNotFound(path: sourceURL)
        }

        let contents = try Data(contentsOf: sourceURL)
        guard isValidAgeKey(contents) else {
            throw CLIError.invalidAgeKeyFile(path: sourceURL)
        }

        let destPath = VaultLocator.resolveAgeKey(globalFlag: global.ageKeyURL)
        if let path = destPath {
            try importToFile(contents: contents, at: path, sourceURL: sourceURL)
        } else {
            #if os(macOS)
                try importToKeychain(contents: contents, sourceURL: sourceURL)
            #else
                let defaultPath = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".config")
                    .appendingPathComponent("sharibako")
                    .appendingPathComponent("age-key")
                try importToFile(contents: contents, at: defaultPath, sourceURL: sourceURL)
            #endif
        }
    }

    /// Writes the imported key to `dest` (0600), then runs the source-deletion flow.
    ///
    /// `lineReader` is the injected prompt-answer seam (defaults to stdin), threaded
    /// through to ``handleSourceDeletion(sourceURL:lineReader:)``.
    func importToFile(
        contents: Data, at dest: URL, sourceURL: URL, lineReader: () -> String? = { readLine() }
    ) throws {
        let parent = dest.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try contents.write(to: dest, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
        fputs("Imported age key to \(dest.path)\n", stderr)
        try handleSourceDeletion(sourceURL: sourceURL, lineReader: lineReader)
    }

    #if os(macOS)
        private func importToKeychain(contents: Data, sourceURL: URL) throws {
            let keychain = KeychainAgeKeyProvider()
            try keychain.storeIdentity(contents)
            fputs("Imported age key to Keychain.\n", stderr)
            try handleSourceDeletion(sourceURL: sourceURL)
        }
    #endif

    /// Deletes, keeps, or prompts about the source file per `--delete-source`/`--keep-source`.
    ///
    /// `lineReader` is the injected prompt-answer seam (defaults to stdin) so tests
    /// can drive the deletion confirmation without a terminal.
    func handleSourceDeletion(sourceURL: URL, lineReader: () -> String? = { readLine() }) throws {
        if keepSource { return }
        if deleteSource {
            try FileManager.default.removeItem(at: sourceURL)
            fputs("Deleted source file at \(sourceURL.path)\n", stderr)
            return
        }
        fputs("Delete the source file at \(sourceURL.path)? [y/N] ", stderr)
        let answer = lineReader() ?? ""
        if answer.lowercased().hasPrefix("y") {
            try FileManager.default.removeItem(at: sourceURL)
            fputs("Deleted source file.\n", stderr)
        }
    }
}

// MARK: - key export

/// Exports the public key (default) or the raw private key (with explicit flag).
struct ExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export the age public (or private) key."
    )

    @OptionGroup var global: GlobalOptions

    @Flag(help: "Export the public recipient key (default).")
    var `public`: Bool = false

    @Flag(help: "Export the raw private key (requires --i-know-this-is-plaintext).")
    var `private`: Bool = false

    @Flag(
        name: .customLong("i-know-this-is-plaintext"),
        help: "Acknowledge that the private key will be printed in plaintext.")
    var iKnowThisIsPlaintext: Bool = false

    func validate() throws {
        // Without this guard `--public --private` silently exported the
        // PRIVATE key — the private branch was checked first.
        if `public` && `private` {
            throw ValidationError("Specify at most one of --public or --private.")
        }
    }

    func run() async throws {
        do { try _run() } catch { ErrorReporter.report(error, json: global.json) }
    }

    // MARK: - Internal for testing

    // _run: leading-underscore testable-entry-point convention (.swift-format NoLeadingUnderscores: false).
    // swiftlint:disable:next identifier_name
    func _run() throws {
        if `private` {
            guard iKnowThisIsPlaintext else {
                throw CLIError.exportRequiresPlaintextAcknowledgement
            }
            let rawKey = try loadRawKey()
            print(rawKey, terminator: "")
            return
        }
        // Default: export public key.
        let rawKey = try loadRawKey()
        let publicKey = try extractPublicKey(from: rawKey)
        print(publicKey)
    }

    /// Loads the raw private key as a `String`.
    func loadRawKey() throws -> String {
        let provider = VaultLocator.resolveProvider(globalFlag: global.ageKeyURL)
        let handle = try provider.loadIdentity(reason: "Export age key")
        defer { handle.release() }
        let data = try Data(contentsOf: handle.url)
        return String(bytes: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Shared helpers

/// Validates that `data` starts with an age secret key header.
func isValidAgeKey(_ data: Data) -> Bool {
    let header = "AGE-SECRET-KEY-"
    guard let text = String(bytes: data, encoding: .utf8) else { return false }
    let firstLine = text.split(separator: "\n", maxSplits: 5).first { !$0.hasPrefix("#") }
    return firstLine.map { $0.hasPrefix(header) || $0.hasPrefix("AGE-PLUGIN-") } ?? false
}

/// Extracts the `age1…` public key from a `URL` pointing at an age key file.
func extractPublicKey(from url: URL) throws -> String {
    let contents = try String(contentsOf: url, encoding: .utf8)
    return try extractPublicKey(from: contents)
}

/// Extracts the `age1…` public key from a string containing the age key contents.
func extractPublicKey(from contents: String) throws -> String {
    let prefix = "# public key: "
    for line in contents.split(whereSeparator: \.isNewline) where line.hasPrefix(prefix) {
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
    throw CLIError.publicKeyHeaderMissing
}
