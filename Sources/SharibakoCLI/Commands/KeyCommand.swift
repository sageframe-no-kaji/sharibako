import ArgumentParser
import Foundation
import SharibakoCore

/// Parent command grouping `key generate`, `key import`, and `key export`.
struct KeyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "key",
        abstract: "Manage the age identity key.",
        discussion: """
            Manages the single age identity that encrypts and decrypts every \
            secret in the vault. The subcommands are 'generate' (create a fresh \
            key pair - and, on first use, the vault it protects), 'import' (adopt \
            an existing age private-key file), and 'export' (print the public \
            recipient key, or the raw private key with an explicit acknowledgement).

            WHERE THE KEY LIVES

            Without --age-key, on macOS the private key is stored in the Keychain \
            with Touch ID gating; on Linux it is written to \
            ~/.config/sharibako/age-key as a 0600 plaintext file. With --age-key \
            <path> (or SHARIBAKO_AGE_KEY) the key is a file at that path on either \
            platform, and Touch ID is not involved.

            The age key is the only thing that decrypts the vault. It is never \
            escrowed and cannot be recovered if lost - back up the recipient key \
            somewhere durable off the machine that holds the vault. Losing the key \
            means rotating every secret at its provider and starting a new vault.

            Run 'sharibako key <subcommand> --help' for the specifics of each.
            """,
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
        abstract: "Generate a new age key pair.",
        discussion: """
            Generates a fresh age key pair and stores the private key: in the \
            macOS Keychain (Touch ID gated) by default, or to a file when \
            --age-key <path> is given (or on Linux). The public recipient key is \
            printed - save it somewhere durable off the machine, because it is \
            the string you back up and the vault cannot be recovered without the \
            private key. This is also the bootstrap command on a fresh install: \
            it creates the vault directory alongside the key.

            'generate' refuses to clobber an existing key unless --force is given, \
            and even then confirms interactively unless --yes is also passed - \
            replacing the key that decrypts your vault makes every existing \
            secret unreadable, so the two-flag gate is deliberate. Generation is \
            staged and swapped into place atomically: if key creation fails, the \
            existing key (the only thing that decrypts the vault) survives \
            untouched.

            EXAMPLES

            First-time bootstrap (Keychain on macOS):
              sharibako key generate

            Generate a file-based key for Linux or CI:
              sharibako key generate --age-key ~/.config/sharibako/age-key

            Deliberately replace an existing key, no prompt:
              sharibako key generate --force --yes

            EXIT CODES

            Exits 2 when a key already exists and --force was not given.
            """
    )

    @OptionGroup var global: GlobalOptions

    /// Overwrite an existing key when present.
    @Flag(
        help: "Replace an existing age key (refuses without it, exit 2). Destroys access to the current vault."
    )
    var force: Bool = false

    /// Skip the interactive confirmation prompt when `--force` is used.
    @Flag(help: "Skip the replacement confirmation prompt (used with --force).")
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
        abstract: "Import an existing age key file.",
        discussion: """
            Adopts an existing age private-key file as this vault's identity: on \
            macOS (without --age-key) it is stored in the Keychain; otherwise it \
            is written to the file location (mode 0600). The source file is \
            validated to look like an age identity before anything is stored. Use \
            this to move a vault to a new machine (clone the vault, import the \
            key), or to switch from a file-based key to the Keychain.

            After importing, Sharibako asks whether to delete the source file - \
            leaving a second copy of your private key lying around is a leak. \
            --delete-source removes it without asking; --keep-source keeps it \
            without asking. Give at most one.

            EXAMPLES

            Import a key and be prompted about the source file:
              sharibako key import ~/backup/age-key

            Import and delete the source in one step:
              sharibako key import /Volumes/USB/age-key --delete-source

            EXIT CODES

            Exits 3 when the source file does not exist, 2 when it is not a valid \
            age identity.
            """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Path to the age private-key file to import.")
    var sourcePath: String

    @Flag(name: .customLong("delete-source"), help: "Delete the source file after import (no prompt).")
    var deleteSource: Bool = false

    @Flag(name: .customLong("keep-source"), help: "Keep the source file (skip the deletion prompt).")
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
        abstract: "Export the age public (or private) key.",
        discussion: """
            Prints the vault's age public recipient key (the age1... string) by \
            default - safe to share, it is what encrypts secrets and appears in \
            git history. This is the string to save as your durable off-machine \
            backup reference.

            With --private, 'export' prints the RAW PRIVATE KEY to stdout in \
            plaintext. Because that is the one secret that decrypts your entire \
            vault, it requires the explicit --i-know-this-is-plaintext \
            acknowledgement; without it the command refuses. On macOS, reading \
            the private key triggers Touch ID. Redirect --private output only to \
            a destination you trust and intend to protect (an encrypted USB, a \
            password manager) - never to a file in a synced or git-tracked \
            directory.

            EXAMPLES

            Print the public recipient key to back up:
              sharibako key export

            Export the private key to an encrypted volume (acknowledged):
              sharibako key export --private --i-know-this-is-plaintext > /Volumes/CRYPT/age-key

            EXIT CODES

            Exits 2 when --private is given without --i-know-this-is-plaintext, or \
            when both --public and --private are given.
            """
    )

    @OptionGroup var global: GlobalOptions

    @Flag(help: "Export the public recipient key (default).")
    var `public`: Bool = false

    @Flag(help: "Export the raw private key in plaintext (requires --i-know-this-is-plaintext).")
    var `private`: Bool = false

    @Flag(
        name: .customLong("i-know-this-is-plaintext"),
        help: "Acknowledge that the private key will be printed in plaintext (required with --private).")
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
