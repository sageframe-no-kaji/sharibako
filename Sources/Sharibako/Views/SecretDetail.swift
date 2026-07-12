import SharibakoCore
import SwiftUI

/// Detail column of the Workshop.
///
/// Shows a selected secret's value (masked or revealed), notes, link target,
/// and rotation history. Adds edit affordances for value (routes through
/// `rotate`) and notes (routes through `updateNotes`) as distinct submits —
/// a notes edit never rotates the value (Decision 6). When only a scope is
/// selected (no secret yet), shows that scope's marker target instead of the
/// generic empty state (ho-06.1 AT-02 Waymarking Decision 3 — "where would
/// this scope's secrets land").
///
/// **Reveal idiom (Decision 4):** value renders as `••••••••` until the user
/// taps Reveal, which calls `model.reveal(key:inScope:)` (the file-key dev path
/// in tests, the Keychain in the signed app). The plaintext stays visible while
/// this secret is selected; changing selection re-masks via the model's
/// `selectedSecretKey` setter.
///
/// Coverage-excluded: SwiftUI declarative body, not headlessly drivable
/// (ho-05 Decision 8). Edit/rotate/notes logic lives in WorkshopModel (tested).
struct SecretDetail: View {
    @Environment(WorkshopModel.self)
    private var model

    var body: some View {
        Group {
            if let sel = resolvedSelection() {
                detailContent(key: sel.key, scopeID: sel.scopeID, info: sel.info)
            } else if let scopeID = model.selectedScopeID {
                scopeOnlyContent(scopeID: scopeID)
            } else {
                ContentUnavailableView(
                    "No Secret Selected",
                    systemImage: "lock",
                    description: Text("Select a secret to view its details.")
                )
            }
        }
        // Flat pālana ground (ho-06.5 Decision 3).
        .background(Color.ground)
    }

    /// Resolved selection for the detail pane: all three pieces together or nil.
    private struct DetailSelection {
        let key: String
        let scopeID: String
        let info: SecretInfo
    }

    /// Returns the resolved selection when all three pieces of state are present, nil otherwise.
    private func resolvedSelection() -> DetailSelection? {
        guard let key = model.selectedSecretKey,
            let scopeID = model.selectedScopeID,
            let info = model.secrets.first(where: { $0.key == key })
        else { return nil }
        return DetailSelection(key: key, scopeID: scopeID, info: info)
    }

    @ViewBuilder
    private func detailContent(key: String, scopeID: String, info: SecretInfo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Key heading
                Text(key)
                    .font(.title2.monospaced())
                    .textSelection(.enabled)

                // Inline drift banner (AT-02 gate fix): keeps this key's drift
                // status visible while you're on the secret, not only in the
                // scope-overview pane. Renders only after a Check-drift.
                if let drift = model.keyDrift(forScope: scopeID, key: key) {
                    keyDriftBanner(drift: drift)
                }

                Divider()

                // Value section (reveal + edit for .value kind)
                if case .value = info.kind {
                    valueSection(key: key, scopeID: scopeID)
                    notesSection(key: key, scopeID: scopeID)
                }

                // Link target (only for .link kind — no local notes to edit)
                if case .link(let sharedID) = info.kind {
                    linkSection(sharedID: sharedID)
                }

                Divider()

                // History section
                historySection()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(key)
    }

    // MARK: - Scope-only content (marker target)

    /// Shown when a scope is selected but no secret is — names where this
    /// scope's secrets would materialize to, from the scan cache
    /// (``WorkshopModel/markerTargetDescription(forScope:)``), with the two
    /// honest empty states named in AT-02: "not scanned yet" and "no marker
    /// found for this scope".
    @ViewBuilder
    private func scopeOnlyContent(scopeID: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Marker Target", systemImage: "mappin.and.ellipse")
                .font(.headline)
                .foregroundStyle(Color.inkSecondary)

            switch model.markerTargetDescription(forScope: scopeID) {
            case .notScanned:
                Text("Not scanned yet.")
                    .font(.callout)
                    .foregroundStyle(Color.inkTertiary)
            case .notFound:
                Text("No marker found for this scope.")
                    .font(.callout)
                    .foregroundStyle(Color.inkTertiary)
            case .found(let markerDirectory, let targetURL):
                VStack(alignment: .leading, spacing: 4) {
                    Text(markerDirectory.path)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                    Text("Materializes to \(targetURL.path)")
                        .font(.caption)
                        .foregroundStyle(Color.inkSecondary)
                        .textSelection(.enabled)
                }
            }

            driftSection(scopeID: scopeID)

            Spacer()

            Text("Select a secret to view its details.")
                .font(.callout)
                .foregroundStyle(Color.inkTertiary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Drift section (AT-02)

    /// Per-key drift for the selected scope, from the session drift cache
    /// (``WorkshopModel/driftReport(forScope:)``, Decision 3).
    ///
    /// Renders only after a Check-drift has run for the scope; before that it
    /// states the honest empty state rather than implying "in sync". Never
    /// surfaces plaintext or the SHA digests — a plain-language status per key
    /// (from the model) is the whole truth. When the scope is drifted, offers
    /// Reconcile, which routes through the existing `materializeSelectedScope`
    /// flow and its drift confirmation (no second write path).
    @ViewBuilder
    private func driftSection(scopeID: String) -> some View {
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            Label("Drift", systemImage: "arrow.triangle.branch")
                .font(.headline)
                .foregroundStyle(Color.inkSecondary)

            if let report = model.driftReport(forScope: scopeID) {
                if report.owned.isEmpty {
                    Text("This scope owns no keys to check.")
                        .font(.callout)
                        .foregroundStyle(Color.inkTertiary)
                } else {
                    ForEach(Array(report.owned.enumerated()), id: \.offset) { _, drift in
                        HStack(spacing: 8) {
                            Text(WorkshopModel.driftKey(drift))
                                .font(.system(.callout, design: .monospaced))
                            Spacer(minLength: 8)
                            // Drifted keys read red at a glance; in-sync stays
                            // quiet secondary (gate finding).
                            Text(WorkshopModel.driftStatusLabel(for: drift))
                                .font(.callout)
                                .foregroundStyle(WorkshopModel.isKeyDrifted(drift) ? Color.drift : Color.inkSecondary)
                        }
                    }
                    if let badge = model.driftBadge(forScope: scopeID), badge != .clean {
                        Button("Reconcile") {
                            Task { await model.materializeSelectedScope() }
                        }
                        .primaryActionButton()
                        .disabled(model.activity != nil)
                        .help("Overwrite the .env with vault values (asks before overwriting drift)")
                    }
                }
            } else {
                Text("No drift check yet — use Check Drift in the toolbar.")
                    .font(.callout)
                    .foregroundStyle(Color.inkTertiary)
            }
        }
    }

    /// The selected secret's inline drift status, with Reconcile when it has
    /// drifted (AT-02 gate fix — drift stays reachable while on a key).
    @ViewBuilder
    private func keyDriftBanner(drift: KeyDrift) -> some View {
        let drifted = WorkshopModel.isKeyDrifted(drift)
        HStack(spacing: 8) {
            Image(systemName: drifted ? "exclamationmark.triangle.fill" : "checkmark.seal")
                .foregroundStyle(drifted ? Color.drift : Color.inkSecondary)
            Text(WorkshopModel.driftStatusLabel(for: drift))
                .font(.callout)
                .foregroundStyle(drifted ? Color.drift : Color.inkSecondary)
            Spacer()
            if drifted {
                Button("Reconcile") {
                    Task { await model.materializeSelectedScope() }
                }
                .primaryActionButton()
                .disabled(model.activity != nil)
                .help("Overwrite the .env with vault values (asks before overwriting drift)")
            }
        }
        .padding(10)
        .background(Color.groundDeep)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Value section

    @ViewBuilder
    private func valueSection(key: String, scopeID: String) -> some View {
        ValueEditSection(key: key, scopeID: scopeID)
    }

    // MARK: - Notes section

    @ViewBuilder
    private func notesSection(key: String, scopeID: String) -> some View {
        NotesEditSection(key: key, scopeID: scopeID)
    }

    // MARK: - Link target section

    @ViewBuilder
    private func linkSection(sharedID: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Linked to shared entry", systemImage: "link")
                .font(.headline)
                .foregroundStyle(Color.inkSecondary)

            Text(sharedID)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Color.inkSecondary)
                .textSelection(.enabled)
        }
    }

    // MARK: - History section

    @ViewBuilder
    private func historySection() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Rotation History", systemImage: "clock.arrow.circlepath")
                .font(.headline)
                .foregroundStyle(Color.inkSecondary)

            if model.history.isEmpty {
                Text("No history — file is untracked or the vault has no git repository.")
                    .foregroundStyle(Color.inkTertiary)
                    .font(.callout)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.history, id: \.shortSHA) { entry in
                        HistoryRow(entry: entry)
                    }
                }
            }
        }
    }
}

// MARK: - Value edit section

/// Reveal-and-rotate widget for a `.value` secret.
///
/// Shows the masked/revealed value with Hide and Copy affordances.
/// "Edit Value" opens an inline edit that submits via `model.editValue` (rotate)
/// and re-masks the field afterward. Editing value and notes are distinct submits
/// so a notes edit never bumps `rotated_at` (Decision 6).
///
/// Coverage-excluded as a private View struct inside the detail pane (ho-05 Decision 8).
private struct ValueEditSection: View {
    @Environment(WorkshopModel.self)
    private var model

    let key: String
    let scopeID: String

    @State private var isEditing = false
    @State private var editValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Value", systemImage: "lock.rectangle")
                    .font(.headline)
                    .foregroundStyle(Color.inkSecondary)
                Spacer()
                if !isEditing {
                    Button("Edit") {
                        isEditing = true
                        // Prefill ONLY when the value is already revealed for
                        // this key (ho-06.1 AT-03 Decision 5) — an unrevealed
                        // value must never be decrypted just to prefill the
                        // edit field. `model.revealedValue` is only ever the
                        // plaintext for `key` (WorkshopModel's invariant: a
                        // selection change clears it first), so this check is
                        // sufficient without re-checking `selectedSecretKey`.
                        editValue = model.revealedValue ?? ""
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                }
            }

            if isEditing {
                // Distinct edit path for value — submits via rotate (editValue intent).
                VStack(alignment: .leading, spacing: 6) {
                    RevealableSecureField(placeholder: "New value", text: $editValue)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button("Cancel") {
                            isEditing = false
                            editValue = ""
                        }
                        .buttonStyle(.borderless)
                        Spacer()
                        Button("Rotate Value") {
                            model.editValue(key: key, inScope: scopeID, newValue: editValue)
                            isEditing = false
                            editValue = ""
                        }
                        .primaryActionButton()
                        .disabled(editValue.isEmpty)
                    }
                }
                .padding(10)
                .background(Color.groundDeep)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if let revealed = model.revealedValue {
                HStack(alignment: .top, spacing: 8) {
                    Text(revealed)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        model.maskValue()
                    } label: {
                        Label("Hide", systemImage: "eye.slash")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Hide the revealed value")

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(revealed, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy to clipboard")
                }
                .padding(10)
                .background(Color.accentMoss.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                HStack(spacing: 8) {
                    Text("••••••••")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(Color.inkSecondary)

                    Spacer()

                    Button("Reveal") {
                        model.reveal(key: key, inScope: scopeID)
                    }
                    .primaryActionButton()
                    .help("Reveal the secret value using Touch ID or the dev age key")
                }
                .padding(10)
                .background(Color.groundDeep)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

// MARK: - Notes edit section

/// Notes display-and-edit widget for a `.value` secret.
///
/// Notes edits submit via `model.editNotes` → `VaultCore.updateNotes`, which
/// preserves `value` and `rotated_at`. A notes edit is categorically distinct
/// from a value edit (Decision 6) — they must not share a submit button.
///
/// Coverage-excluded as a private View struct inside the detail pane (ho-05 Decision 8).
private struct NotesEditSection: View {
    @Environment(WorkshopModel.self)
    private var model

    let key: String
    let scopeID: String

    @State private var isEditing = false
    @State private var editNotes = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Notes", systemImage: "note.text")
                    .font(.headline)
                    .foregroundStyle(Color.inkSecondary)
                Spacer()
                if !isEditing {
                    Button("Edit Notes") {
                        isEditing = true
                        // Prefill ONLY when the note is already revealed for
                        // this key — the same rule as the value editor: an
                        // unrevealed note must never be decrypted just to
                        // prefill the edit field. Before this, the field
                        // always opened blank even with the revealed note
                        // sitting right above it (ho-06.5 gate finding).
                        editNotes = model.revealedNotes ?? ""
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                }
            }

            if isEditing {
                VStack(alignment: .leading, spacing: 6) {
                    TextField(
                        "Notes (leave blank to clear)",
                        text: $editNotes,
                        axis: .vertical
                    )
                    .lineLimit(3...6)
                    .textFieldStyle(.roundedBorder)

                    HStack {
                        Button("Cancel") {
                            isEditing = false
                            editNotes = ""
                        }
                        .buttonStyle(.borderless)
                        Spacer()
                        Button("Save Notes") {
                            // Distinct submit path — routes through updateNotes, not rotate.
                            let normalized: String? = editNotes.isEmpty ? nil : editNotes
                            model.editNotes(key: key, inScope: scopeID, notes: normalized)
                            isEditing = false
                            editNotes = ""
                        }
                        .primaryActionButton()
                    }
                }
                .padding(10)
                .background(Color.groundDeep)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if let notes = model.revealedNotes {
                // Notes decrypt alongside the value on reveal; show them.
                Text(notes)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.groundDeep)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if model.revealedValue != nil {
                // Revealed, but the payload carries no notes.
                Text("No notes.")
                    .font(.callout)
                    .foregroundStyle(Color.inkTertiary)
            } else {
                Text("(reveal to see notes, or edit to update)")
                    .font(.callout)
                    .foregroundStyle(Color.inkTertiary)
            }
        }
    }
}

// MARK: - History row

/// One row in the rotation history list.
private struct HistoryRow: View {
    let entry: CommitInfo

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.shortSHA)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.inkSecondary)
                .frame(width: 56, alignment: .leading)

            Text(entry.date)
                .font(.caption)
                .foregroundStyle(Color.inkSecondary)
                .frame(width: 80, alignment: .leading)

            Text(entry.subject)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .textSelection(.enabled)
    }
}

// MARK: - Primary action button treatment

extension View {
    /// The Workshop's call-to-action button treatment (ho-06.2 gate polish):
    /// a little more space and an accent color shift so the next action to
    /// press stands out from the calm, quiet UI without shouting.
    ///
    /// Applied to primary actions (Reveal, Reconcile, Rotate Value, Save
    /// Notes); secondary actions (Cancel, Edit, Hide/Copy) stay borderless so
    /// the emphasis reads as a single clear "do this next".
    func primaryActionButton() -> some View {
        buttonStyle(.borderedProminent)
            .controlSize(.large)
    }
}
