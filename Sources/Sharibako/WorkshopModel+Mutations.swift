import Foundation
import SharibakoCore

/// Mutation intents: create scope/secret/shared-entry, rotate value, edit
/// notes (ho-05 AT-03, Decision 5; creation announces added ho-06.1 AT-02
/// Decision 6).
///
/// Split out of `WorkshopModel.swift` to keep that file under SwiftLint's
/// `file_length` ceiling once AT-02's waymarking and pulse support landed —
/// a mechanical reorganization, not a change in ownership; these intents
/// still route through the same `VaultCore` construction and error-mapping
/// pattern as every other extension. Follows the `Conduit` +
/// `Conduit+Remote.swift` precedent.
extension WorkshopModel {
    /// Creates a new scope and refreshes the sidebar, selecting the new scope.
    ///
    /// Maps thrown `VaultError` to ``WorkshopModel/errorMessage``; never
    /// crashes the window. Announces via ``WorkshopModel/statusMessage`` on
    /// success (AT-02 Decision 6 — creation has no visible home of its own
    /// until the sidebar refreshes, so the action must say what it did).
    func addScope(id: String, type: ScopeType, displayName: String?) {
        guard case .open(let vaultURL) = vaultState else { return }
        do {
            let core = try VaultCore(vaultURL: vaultURL)
            let name = displayName.flatMap { $0.isEmpty ? nil : $0 }
            try core.createScope(id, type: type, displayName: name)
            loadScopes()
            selectedScopeID = id
            statusMessage = "Created scope \(id)."
            errorMessage = nil
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// Adds a secret to the given scope and refreshes the secret list.
    ///
    /// Requires the age key because `addSecret` encrypts. Uses the current age
    /// key provider (file bypass in dev; Keychain in the signed app).
    /// Announces via ``WorkshopModel/statusMessage`` on success (AT-02
    /// Decision 6).
    func addSecret(key: String, value: String, notes: String?, inScope scopeID: String) {
        guard case .open(let vaultURL) = vaultState else { return }
        let provider = makeAgeKeyProvider()
        let handle: AgeKeyHandle
        do {
            handle = try provider.loadIdentity(reason: "Encrypt new secret \(key) in \(scopeID)")
        } catch {
            errorMessage = "Could not load age key: \(error)"
            return
        }
        defer { handle.release() }
        do {
            let core = try VaultCore(vaultURL: vaultURL, ageKeyURL: handle.url)
            let normalizedNotes = notes.flatMap { $0.isEmpty ? nil : $0 }
            try core.addSecret(key, value: value, inScope: scopeID, notes: normalizedNotes)
            if selectedScopeID == scopeID {
                loadSecrets(for: scopeID)
            }
            statusMessage = "Added \(key) to \(scopeID)."
            errorMessage = nil
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// Adds a new shared entry to `shared/`.
    ///
    /// Requires the age key for encryption. Maps errors to
    /// ``WorkshopModel/errorMessage``. Announces via
    /// ``WorkshopModel/statusMessage`` on success (AT-02 Decision 6) — shared
    /// entries especially have no visible home of their own until ho-07's
    /// browser, so the announce is the only confirmation the operator gets.
    func addSharedEntry(id: String, value: String, notes: String?) {
        guard case .open(let vaultURL) = vaultState else { return }
        let provider = makeAgeKeyProvider()
        let handle: AgeKeyHandle
        do {
            handle = try provider.loadIdentity(reason: "Encrypt new shared entry \(id)")
        } catch {
            errorMessage = "Could not load age key: \(error)"
            return
        }
        defer { handle.release() }
        do {
            let core = try VaultCore(vaultURL: vaultURL, ageKeyURL: handle.url)
            let normalizedNotes = notes.flatMap { $0.isEmpty ? nil : $0 }
            try core.addSharedEntry(id, value: value, notes: normalizedNotes)
            statusMessage = "Created shared entry \(id)."
            errorMessage = nil
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// Rotates a scope-local secret to a new value.
    ///
    /// Clears any stale revealed value for that key so the caller must
    /// re-reveal the new ciphertext via Touch ID (Decision 4).
    func editValue(key: String, inScope scopeID: String, newValue: String) {
        guard case .open(let vaultURL) = vaultState else { return }
        let provider = makeAgeKeyProvider()
        let handle: AgeKeyHandle
        do {
            handle = try provider.loadIdentity(reason: "Rotate \(key) in \(scopeID)")
        } catch {
            errorMessage = "Could not load age key: \(error)"
            return
        }
        defer { handle.release() }
        do {
            let core = try VaultCore(vaultURL: vaultURL, ageKeyURL: handle.url)
            try core.rotate(key, inScope: scopeID, newValue: newValue)
            // Clear stale reveal so the new value must be explicitly re-revealed.
            if selectedSecretKey == key {
                revealedValue = nil
                revealedNotes = nil
            }
            errorMessage = nil
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// Updates a secret's notes without changing its value or rotation date.
    ///
    /// A notes-only edit is not a rotation and must not bump `rotated_at`;
    /// this routes through `VaultCore.updateNotes`, not `rotate` (Decision 6).
    func editNotes(key: String, inScope scopeID: String, notes: String?) {
        guard case .open(let vaultURL) = vaultState else { return }
        let provider = makeAgeKeyProvider()
        let handle: AgeKeyHandle
        do {
            handle = try provider.loadIdentity(reason: "Edit notes for \(key) in \(scopeID)")
        } catch {
            errorMessage = "Could not load age key: \(error)"
            return
        }
        defer { handle.release() }
        do {
            let core = try VaultCore(vaultURL: vaultURL, ageKeyURL: handle.url)
            let normalized = notes.flatMap { $0.isEmpty ? nil : $0 }
            try core.updateNotes(key, inScope: scopeID, notes: normalized)
            // Keep the displayed notes current when this secret is revealed —
            // the value stays revealed (no rotation happened, Decision 6).
            if selectedSecretKey == key, revealedValue != nil {
                revealedNotes = normalized
            }
            errorMessage = nil
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    // MARK: - Deletion (ho-06.7)

    /// A staged scope deletion awaiting the window's confirmation.
    struct ScopeDeletion: Equatable {
        /// The scope to delete.
        let scopeID: String
        /// How many secrets it holds — for the confirmation's blast-radius line.
        let secretCount: Int
    }

    /// Stages deletion of the selected scope, to be confirmed in the window.
    ///
    /// Reads the secret count via `inspect` (filenames only — no decryption, no
    /// Touch ID) so the confirmation can name the blast radius, then sets
    /// ``WorkshopModel/pendingScopeDeletion``. A no-op when nothing is selected
    /// or an action is already in flight.
    func requestDeleteSelectedScope() {
        guard activity == nil else { return }
        guard case .open(let vaultURL) = vaultState else { return }
        guard let scopeID = selectedScopeID else { return }
        statusMessage = nil
        let count = (try? VaultCore(vaultURL: vaultURL).inspect(scopeID).count) ?? 0
        pendingScopeDeletion = ScopeDeletion(scopeID: scopeID, secretCount: count)
    }

    /// Dismisses the pending scope deletion (user cancelled).
    func dismissScopeDeletion() {
        pendingScopeDeletion = nil
    }

    /// Deletes the staged scope and refreshes the sidebar.
    ///
    /// Keyless (`VaultCore(vaultURL:)`) — deletion removes files, it never
    /// decrypts, so no age key and no Touch ID. Clears the selection when it
    /// pointed at the deleted scope, announces via ``WorkshopModel/statusMessage``
    /// on success (the sidebar refresh is the only other visible outcome), and
    /// maps any `VaultError` to ``WorkshopModel/errorMessage`` without crashing
    /// the window. Deletion only touches the vault — markers and materialized
    /// .env files are left in place; the removal commits on the next Sync.
    func confirmDeleteScope() {
        guard case .open(let vaultURL) = vaultState else { return }
        guard let deletion = pendingScopeDeletion else { return }
        pendingScopeDeletion = nil
        do {
            let core = try VaultCore(vaultURL: vaultURL)
            try core.deleteScope(deletion.scopeID)
            if selectedScopeID == deletion.scopeID {
                selectedScopeID = nil
            }
            loadScopes()
            statusMessage = "Deleted scope \(deletion.scopeID). Sync to commit the removal."
            errorMessage = nil
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// A staged single-secret deletion awaiting the window's confirmation.
    struct SecretDeletion: Equatable {
        /// The scope holding the key.
        let scopeID: String
        /// The key to delete.
        let key: String
    }

    /// Stages deletion of the selected secret, to be confirmed in the window.
    ///
    /// A no-op when no scope+secret is selected or an action is already in flight.
    func requestDeleteSelectedSecret() {
        guard activity == nil else { return }
        guard case .open = vaultState else { return }
        guard let scopeID = selectedScopeID, let key = selectedSecretKey else { return }
        statusMessage = nil
        pendingSecretDeletion = SecretDeletion(scopeID: scopeID, key: key)
    }

    /// Dismisses the pending secret deletion (user cancelled).
    func dismissSecretDeletion() {
        pendingSecretDeletion = nil
    }

    /// Deletes the staged secret and refreshes the secret list.
    ///
    /// Keyless (`VaultCore(vaultURL:)`) — removal decrypts nothing, so no age key
    /// and no Touch ID. Clears the secret selection when it matched (its setter
    /// re-masks any revealed value), refreshes the list for the scope, announces
    /// via ``WorkshopModel/statusMessage``, and maps any `VaultError` to
    /// ``WorkshopModel/errorMessage``. Only touches the vault; `sync` commits it.
    func confirmDeleteSecret() {
        guard case .open(let vaultURL) = vaultState else { return }
        guard let deletion = pendingSecretDeletion else { return }
        pendingSecretDeletion = nil
        do {
            let core = try VaultCore(vaultURL: vaultURL)
            try core.deleteSecret(deletion.key, inScope: deletion.scopeID)
            if selectedSecretKey == deletion.key {
                selectedSecretKey = nil
            }
            if selectedScopeID == deletion.scopeID {
                loadSecrets(for: deletion.scopeID)
            }
            statusMessage =
                "Deleted key \(deletion.scopeID)/\(deletion.key). Sync to commit the removal."
            errorMessage = nil
        } catch {
            errorMessage = Self.message(for: error)
        }
    }
}
