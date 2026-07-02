import ArgumentParser
import Foundation
import SharibakoCore

/// Initializes a project directory as a sharibako scope.
///
/// Reads `.env`/`.env.local` in the target directory, walks each detected
/// secret through an interactive per-key decision prompt (import as scope-local,
/// link to shared, move to shared, leave alone, skip), then writes the chosen
/// secrets to the vault and drops a `.sharibako` marker binding the directory
/// to its scope.
///
/// Re-running `init` in an already-initialized directory reconciles: it
/// presents only keys the scope does not yet own, and never silently rebinds
/// the directory to a different scope.
///
/// The source `.env` is left byte-for-byte untouched — it is the materialized
/// runtime artifact, not a duplicate to clean up (kamae-2.2).
struct InitCommand: AsyncParsableCommand {
    /// Command configuration.
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Initialize a project directory as a sharibako scope."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Project directory to initialize (defaults to the current directory).")
    var directory: String?

    @Flag(name: .customLong("no-generate"), help: "Do not offer to generate an age key if none exists.")
    var noGenerate: Bool = false

    // MARK: - AsyncParsableCommand

    func run() async throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        do { try _run(cwd: cwd) } catch { ErrorReporter.report(error, json: global.json) }
    }

    // MARK: - Internal for testing

    // swiftlint:disable:next identifier_name
    func _run(
        cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        decisionSource: any IngestDecisionSource = InteractiveIngestPrompt(),
        lineReader: () -> String? = { readLine() }
    ) throws {
        let targetURL = resolveTargetURL(cwd: cwd)
        let vaultURL = try VaultLocator.resolve(globalFlag: global.vaultURL)
        let markerFileURL = targetURL.appendingPathComponent(".sharibako")
        let existingMarker = try loadExistingMarker(at: markerFileURL, vaultURL: vaultURL)
        if let marker = existingMarker {
            print("Directory already initialized as scope '\(marker.scope)'. Reconciling new keys...")
        } else {
            let shouldContinue = try offerKeyGeneration(lineReader: lineReader)
            guard shouldContinue else { return }
        }
        let provider = VaultLocator.resolveProvider(globalFlag: global.ageKeyURL)
        let handle = try provider.loadIdentity(reason: "Encrypt secrets during sharibako init")
        defer { handle.release() }
        let vault = try VaultCore(vaultURL: vaultURL, ageKeyURL: handle.url)
        let materializer = Materializer(vaultCore: vault, vaultURL: vaultURL)
        let fullProposal = try materializer.ingest(directory: targetURL)
        let proposal: ProposedScope
        if let marker = existingMarker {
            proposal = filterProposal(fullProposal, existingScope: marker.scope, vault: vault)
        } else {
            proposal = fullProposal
        }
        let scopeID: String
        let scopeType: ScopeType
        if let marker = existingMarker {
            scopeID = marker.scope
            scopeType = proposal.suggestedScopeType
        } else {
            let selection = try promptScopeIDAndType(proposal: proposal, vault: vault, lineReader: lineReader)
            scopeID = selection.scopeID
            scopeType = selection.scopeType
        }
        if proposal.detectedKeys.isEmpty {
            try acceptEmpty(
                proposal: proposal,
                scopeID: scopeID,
                scopeType: scopeType,
                materializer: materializer,
                markerURL: markerFileURL
            )
            return
        }
        let sharedIDs = try vault.listShared()
        let decisions = try decisionSource.decisions(for: proposal, sharedIDs: sharedIDs)
        try materializer.acceptIngest(
            proposal,
            decisions: decisions,
            scopeID: scopeID,
            scopeType: scopeType
        )
        reportResult(decisions: decisions, scopeID: scopeID, markerURL: markerFileURL)
    }

    // MARK: - Private helpers

    private func resolveTargetURL(cwd: URL) -> URL {
        guard let dir = directory else { return cwd }
        return URL(fileURLWithPath: dir, relativeTo: cwd).standardizedFileURL
    }

    /// Loads the `.sharibako` marker at `markerFileURL` using direct `fileExists`
    /// detection (Decision 7 — avoids the walk-up `resolveMarker(startingFrom:)` and
    /// its home-boundary bug).
    private func loadExistingMarker(at markerFileURL: URL, vaultURL: URL) throws -> ScopeMarker? {
        guard FileManager.default.fileExists(atPath: markerFileURL.path) else { return nil }
        let vault = try VaultCore(vaultURL: vaultURL)
        let materializer = Materializer(vaultCore: vault, vaultURL: vaultURL)
        return try materializer.loadMarker(at: markerFileURL)
    }

    /// Returns `true` when an age key is already available (Keychain item on macOS
    /// or key file on file-based paths), `false` otherwise.
    private func ageKeyExists() -> Bool {
        if let path = VaultLocator.resolveAgeKey(globalFlag: global.ageKeyURL) {
            return FileManager.default.fileExists(atPath: path.path)
        }
        #if os(macOS)
            return KeychainAgeKeyProvider().itemExists()
        #else
            let defaultPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config")
                .appendingPathComponent("sharibako")
                .appendingPathComponent("age-key")
            return FileManager.default.fileExists(atPath: defaultPath.path)
        #endif
    }

    /// Generates an age key via `AgeKeyBootstrap` to the provider-appropriate destination.
    ///
    /// For `--age-key <path>`: writes to that path.
    /// On macOS without `--age-key`: stores in the Keychain.
    /// On Linux without `--age-key`: writes to `~/.config/sharibako/age-key`.
    private func generateKey() throws -> String {
        if let path = VaultLocator.resolveAgeKey(globalFlag: global.ageKeyURL) {
            return try AgeKeyBootstrap.generateToFile(at: path)
        }
        #if os(macOS)
            return try AgeKeyBootstrap.generateToKeychain()
        #else
            let defaultPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config")
                .appendingPathComponent("sharibako")
                .appendingPathComponent("age-key")
            return try AgeKeyBootstrap.generateToFile(at: defaultPath)
        #endif
    }

    /// Checks whether an age key exists and, when absent, offers inline generation.
    ///
    /// - Returns: `true` to continue; `false` when the user declined generation
    ///   and `_run` should return without error.
    /// - Throws: `CLIError.ageKeyFileNotFound` when `--no-generate` is set and no
    ///   key is available.
    private func offerKeyGeneration(lineReader: () -> String?) throws -> Bool {
        guard !ageKeyExists() else { return true }
        guard !noGenerate else {
            let fallbackPath = URL(fileURLWithPath: "~/.config/sharibako/age-key")
            throw CLIError.ageKeyFileNotFound(path: global.ageKeyURL ?? fallbackPath)
        }
        fputs("No age key found. Generate one now? [Y/n] ", stderr)
        let answer = (lineReader() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard answer.isEmpty || answer.hasPrefix("y") else {
            print("Skipped. Run `sharibako key generate` when ready.")
            return false
        }
        let recipient = try generateKey()
        fputs("Save this recipient key somewhere safe:\n", stderr)
        print(recipient)
        return true
    }

    /// Builds a filtered `ProposedScope` containing only keys the scope does not yet own.
    ///
    /// Used for re-init reconcile (Decision 7). Already-owned keys are silently
    /// excluded — they are not re-presented to the decision source. If the scope
    /// cannot be found in the vault (orphaned marker on a new machine), falls back
    /// to returning the full proposal so the practitioner can re-ingest everything.
    private func filterProposal(
        _ full: ProposedScope,
        existingScope: String,
        vault: VaultCore
    ) -> ProposedScope {
        let ownedKeys: Set<String>
        if let infos = try? vault.inspect(existingScope) {
            ownedKeys = Set(infos.map(\.key))
        } else {
            ownedKeys = []
        }
        let newKeys = full.detectedKeys.filter { !ownedKeys.contains($0.key) }
        return ProposedScope(
            directory: full.directory,
            suggestedScopeID: existingScope,
            suggestedScopeType: full.suggestedScopeType,
            detectedKeys: newKeys,
            suggestedKeysNeedingValues: full.suggestedKeysNeedingValues,
            parseWarnings: full.parseWarnings
        )
    }

    /// Named return type for `promptScopeIDAndType`.
    private struct ScopeSelection {
        let scopeID: String
        let scopeType: ScopeType
    }

    /// Prompts for the scope ID (with the suggested default) and scope type, then
    /// checks for collision and asks for confirmation when the chosen ID already exists.
    private func promptScopeIDAndType(
        proposal: ProposedScope,
        vault: VaultCore,
        lineReader: () -> String?
    ) throws -> ScopeSelection {
        fputs("Scope ID [\(proposal.suggestedScopeID)]: ", stderr)
        let rawID = (lineReader() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let scopeID = rawID.isEmpty ? proposal.suggestedScopeID : rawID

        // Collision check: idempotent reuse with explicit confirmation (Decision 3).
        let existingScopes = Set(try vault.listScopes().map(\.identity))
        if existingScopes.contains(scopeID) {
            fputs("Scope '\(scopeID)' already exists — its keys will be added to. Continue? [y/N] ", stderr)
            let confirm = (lineReader() ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard confirm.hasPrefix("y") else {
                fputs("Aborted.\n", stderr)
                throw CLIError.aborted
            }
        }

        // Scope type: default project-dev; practitioner can override inline.
        fputs("Scope type [project-dev] (project-dev/project-prod/service/machine/other): ", stderr)
        let rawType = (lineReader() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let scopeType = ScopeType(rawValue: rawType) ?? .projectDev

        return ScopeSelection(scopeID: scopeID, scopeType: scopeType)
    }

    /// Handles the empty-`.env` case: writes a zero-secret marker, then returns.
    ///
    /// An empty scope is legitimate — the practitioner can `sharibako add` secrets
    /// later. This mirrors `git init` in an empty directory: the binding is the
    /// first-class act, not the initial content.
    private func acceptEmpty(
        proposal: ProposedScope,
        scopeID: String,
        scopeType: ScopeType,
        materializer: Materializer,
        markerURL: URL
    ) throws {
        try materializer.acceptIngest(
            proposal,
            decisions: [],
            scopeID: scopeID,
            scopeType: scopeType
        )
        print("No `.env` secrets found. Initialized scope '\(scopeID)' at \(markerURL.path) with 0 secrets.")
        print("Add secrets later with `sharibako add`.")
    }

    /// Prints the post-ingest decision summary.
    private func reportResult(decisions: [KeyDecision], scopeID: String, markerURL: URL) {
        var imported = 0
        var linked = 0
        var moved = 0
        var leftAlone = 0
        var skipped = 0
        for decision in decisions {
            switch decision {
            case .importAsLocal: imported += 1
            case .linkToShared: linked += 1
            case .moveToShared: moved += 1
            case .leaveAlone: leftAlone += 1
            case .skip: skipped += 1
            }
        }
        print("Initialized scope '\(scopeID)' at \(markerURL.path)")
        // swiftlint:disable:next line_length
        print("imported \(imported)  linked \(linked)  moved \(moved)  left alone \(leftAlone)  skipped \(skipped)")
    }
}
