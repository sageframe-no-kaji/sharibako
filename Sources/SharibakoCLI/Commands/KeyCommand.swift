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
    @Flag(help: "Force overwrite of an existing key.")
    var force: Bool = false

    /// Skip the interactive confirmation prompt when `--force` is used.
    @Flag(help: "Skip the overwrite confirmation prompt.")
    var yes: Bool = false

    func run() async throws {
        do { try _run() } catch { ErrorReporter.report(error, json: global.json) }
    }

    private func _run() throws {
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

    func generateToFile(at path: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: path.path) {
            guard force else { throw CLIError.ageKeyAlreadyExists }
            if !yes {
                fputs("Overwrite existing age key at \(path.path)? [y/N] ", stderr)
                let answer = readLine() ?? ""
                guard answer.lowercased().hasPrefix("y") else {
                    fputs("Aborted.\n", stderr)
                    return
                }
            }
            try fileManager.removeItem(at: path)
        }
        // Ensure parent directory exists.
        let parent = path.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        let ageKeygen = try CLIShell.findExecutable("age-keygen")
        let result = try CLIShell.run(ageKeygen, ["-o", path.path])
        guard result.exitCode == 0 else {
            throw VaultError.ageInvocationFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        // Fix permissions to 0600.
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)

        let publicKey = try extractPublicKey(from: path)
        fputs("Save this recipient key somewhere safe:\n", stderr)
        print(publicKey)
    }

    // MARK: - Keychain path (macOS only)

    #if os(macOS)
        private func generateToKeychain() throws {
            let keychain = KeychainAgeKeyProvider()
            if keychain.itemExists() {
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

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("sharibako-keygen-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let ageKeygen = try CLIShell.findExecutable("age-keygen")
            let result = try CLIShell.run(ageKeygen, ["-o", tempURL.path])
            guard result.exitCode == 0 else {
                throw VaultError.ageInvocationFailed(exitCode: result.exitCode, stderr: result.stderr)
            }

            let data = try Data(contentsOf: tempURL)
            try keychain.storeIdentity(data)

            let publicKey = try extractPublicKey(from: tempURL)
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

    private func _run() throws {
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

    func importToFile(contents: Data, at dest: URL, sourceURL: URL) throws {
        let parent = dest.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try contents.write(to: dest, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
        fputs("Imported age key to \(dest.path)\n", stderr)
        try handleSourceDeletion(sourceURL: sourceURL)
    }

    #if os(macOS)
        private func importToKeychain(contents: Data, sourceURL: URL) throws {
            let keychain = KeychainAgeKeyProvider()
            try keychain.storeIdentity(contents)
            fputs("Imported age key to Keychain.\n", stderr)
            try handleSourceDeletion(sourceURL: sourceURL)
        }
    #endif

    func handleSourceDeletion(sourceURL: URL) throws {
        if keepSource { return }
        if deleteSource {
            try FileManager.default.removeItem(at: sourceURL)
            fputs("Deleted source file at \(sourceURL.path)\n", stderr)
            return
        }
        fputs("Delete the source file at \(sourceURL.path)? [y/N] ", stderr)
        let answer = readLine() ?? ""
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

    func run() async throws {
        do { try _run() } catch { ErrorReporter.report(error, json: global.json) }
    }

    private func _run() throws {
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
