import SharibakoCore
import SwiftUI

/// The GUI ingest flow's sheet (ho-06.3 Decision 6): scan result → per-key
/// decision list → scope ID/type confirmation → commit, presented modally
/// over the main window from three entry points — the action panel's
/// **Ingest Project…** verb, the first-run wizard's finish hand-off, and —
/// AT-03 — orphaned-marker rows.
///
/// All branching logic lives in `WorkshopModel+Ingest.swift` (tested): this
/// view reads `model.ingest.session` and calls its intents (Do Not §4).
/// Which verdicts are offered for a key (link only when shared entries
/// exist), whether the reconcile/collision banners show, and the summary
/// text are all already-computed reads off ``WorkshopModel/IngestSession`` —
/// the same "no decision logic in the view" posture `ActionPanel` and
/// `FirstRunWizard` already follow. The per-key verdict picker's mapping
/// from a flat `Picker` tag onto a `KeyDecision`'s associated-value shape is
/// UI plumbing, not a business rule — the `remoteURLBinding` /
/// `Binding(get:set:)` precedent throughout this module.
///
/// Coverage-excluded: SwiftUI declarative body, not headlessly drivable
/// (ho-05 Decision 8) — see `.github/workflows/ci.yml`'s `EXCLUDED` regex.
struct IngestSheet: View {
    @Environment(WorkshopModel.self)
    private var model

    /// `true` while `commitIngest()` is in flight — disables Commit/Cancel
    /// against a double-tap (the `FirstRunWizard.isCreating` precedent).
    @State private var isCommitting = false

    var body: some View {
        if let session = model.ingest.session {
            content(for: session)
        }
    }

    @ViewBuilder
    private func content(for session: WorkshopModel.IngestSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(session)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    scopeSection(session)
                    bannerSection(session)
                    warningsSection(session)
                    needingValuesSection(session)
                    decisionRows(session)
                    if let error = model.ingest.errorMessage {
                        Text(error)
                            .foregroundStyle(Color.drift)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer(session)
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(Color.ground)
    }

    // MARK: - Header

    private func header(_ session: WorkshopModel.IngestSession) -> some View {
        HStack {
            Text("Import \(session.directory.lastPathComponent)")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.ink)
            Spacer()
            Text("\(session.proposal.detectedKeys.count) secret(s) detected")
                .font(.caption)
                .foregroundStyle(Color.inkTertiary)
        }
        .padding(20)
    }

    // MARK: - Scope section

    private func scopeSection(_ session: WorkshopModel.IngestSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Scope ID")
                    .foregroundStyle(Color.inkSecondary)
                TextField(
                    "scope-id",
                    text: Binding(
                        get: { session.scopeID },
                        set: { model.setIngestScopeID($0) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .disabled(session.isReconcile)
            }
            if !VaultCore.isValidIdentifier(session.scopeID) {
                Text("Invalid scope ID — use letters, digits, and ._- (no path separators).")
                    .font(.caption)
                    .foregroundStyle(Color.drift)
            }
            HStack {
                Text("Scope type")
                    .foregroundStyle(Color.inkSecondary)
                Picker(
                    "Scope type",
                    selection: Binding(
                        get: { session.scopeType },
                        set: { model.setIngestScopeType($0) }
                    )
                ) {
                    Text("Project — dev").tag(ScopeType.projectDev)
                    Text("Project — prod").tag(ScopeType.projectProd)
                    Text("Service").tag(ScopeType.service)
                    Text("Machine").tag(ScopeType.machine)
                    Text("Other").tag(ScopeType.other)
                }
                .labelsHidden()
                .disabled(session.isReconcile)
            }
        }
    }

    @ViewBuilder
    private func bannerSection(_ session: WorkshopModel.IngestSession) -> some View {
        if session.isReconcile {
            Label(
                "Reconciling — only keys this scope doesn't already own are listed.",
                systemImage: "arrow.triangle.2.circlepath"
            )
            .foregroundStyle(Color.inkSecondary)
        }
        if session.isScopeCollision {
            Label(
                "Scope '\(session.scopeID)' already exists — these keys will be added to it.",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(Color.drift)
        }
    }

    @ViewBuilder
    private func warningsSection(_ session: WorkshopModel.IngestSession) -> some View {
        if !session.proposal.parseWarnings.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(session.proposal.parseWarnings.enumerated()), id: \.offset) { _, warning in
                    Text("Warning: \(warning.reason) (\(warning.file.lastPathComponent):\(warning.lineNumber))")
                        .font(.caption)
                        .foregroundStyle(Color.drift)
                }
            }
        }
    }

    @ViewBuilder
    private func needingValuesSection(_ session: WorkshopModel.IngestSession) -> some View {
        if !session.proposal.suggestedKeysNeedingValues.isEmpty {
            Text(
                "No value found — add later with Add Secret: "
                    + session.proposal.suggestedKeysNeedingValues.joined(separator: ", ")
            )
            .font(.caption)
            .foregroundStyle(Color.inkTertiary)
        }
    }

    // MARK: - Decision rows

    private func decisionRows(_ session: WorkshopModel.IngestSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Secrets")
                .font(.headline)
                .foregroundStyle(Color.ink)
            ForEach(session.proposal.detectedKeys, id: \.key) { key in
                decisionRow(for: key, session: session)
                Divider()
            }
        }
    }

    private func decisionRow(for key: DetectedKey, session: WorkshopModel.IngestSession) -> some View {
        let decision = session.decisions[key.key] ?? .importAsLocal(key: key.key)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(key.key)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Color.ink)
                if let matched = key.nameMatchedSharedID {
                    Text("matches shared '\(matched)'")
                        .font(.caption)
                        .foregroundStyle(Color.inkTertiary)
                }
                Spacer()
                Text("••••••••")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Color.inkTertiary)
            }
            Picker("Verdict", selection: verdictBinding(for: key, session: session)) {
                Text("Import as scope-local").tag(DecisionKind.importAsLocal)
                if !session.sharedIDs.isEmpty {
                    Text("Link to shared").tag(DecisionKind.linkToShared)
                }
                Text("Move to shared").tag(DecisionKind.moveToShared)
                Text("Leave alone").tag(DecisionKind.leaveAlone)
                Text("Skip").tag(DecisionKind.skip)
            }
            .labelsHidden()
            .pickerStyle(.menu)

            if case .linkToShared(_, let sharedID) = decision {
                Picker(
                    "Shared entry",
                    selection: Binding(
                        get: { sharedID },
                        set: { model.setIngestDecision(.linkToShared(key: key.key, sharedID: $0), forKey: key.key) }
                    )
                ) {
                    ForEach(session.sharedIDs, id: \.self) { id in
                        Text(id).tag(id)
                    }
                }
                .labelsHidden()
            }
            if case .moveToShared(_, let newSharedID) = decision {
                TextField(
                    "New shared entry ID",
                    text: Binding(
                        get: { newSharedID },
                        set: {
                            model.setIngestDecision(.moveToShared(key: key.key, newSharedID: $0), forKey: key.key)
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            }
        }
        .padding(.vertical, 4)
    }

    /// One labeled row's `Picker` selection, mapped from a `KeyDecision`
    /// onto ``DecisionKind``.
    ///
    /// UI plumbing, not a business rule — see the type doc.
    private func verdictBinding(
        for key: DetectedKey, session: WorkshopModel.IngestSession
    ) -> Binding<DecisionKind> {
        Binding(
            get: { DecisionKind(session.decisions[key.key] ?? .importAsLocal(key: key.key)) },
            set: { kind in
                model.setIngestDecision(
                    Self.makeDecision(kind: kind, key: key, session: session), forKey: key.key)
            }
        )
    }

    /// Builds a fresh `KeyDecision` for a chosen ``DecisionKind``, filling in
    /// a sensible default target (the name-matched shared ID when present,
    /// else the first shared entry, for "link"; a sanitized key name for
    /// "move") — the operator can still retype either target.
    private static func makeDecision(
        kind: DecisionKind, key: DetectedKey, session: WorkshopModel.IngestSession
    ) -> KeyDecision {
        switch kind {
        case .importAsLocal:
            return .importAsLocal(key: key.key)
        case .linkToShared:
            let target = key.nameMatchedSharedID ?? session.sharedIDs.first ?? ""
            return .linkToShared(key: key.key, sharedID: target)
        case .moveToShared:
            return .moveToShared(key: key.key, newSharedID: sanitizedSharedID(from: key.key))
        case .leaveAlone:
            return .leaveAlone(key: key.key)
        case .skip:
            return .skip(key: key.key)
        }
    }

    // MARK: - Footer

    private func footer(_ session: WorkshopModel.IngestSession) -> some View {
        HStack {
            Button("Cancel") {
                model.cancelIngest()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(isCommitting)
            Spacer()
            Button(isCommitting ? "Importing…" : "Import") {
                commit()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isCommitting || !VaultCore.isValidIdentifier(session.scopeID))
        }
        .padding(20)
    }

    private func commit() {
        isCommitting = true
        Task {
            await model.commitIngest()
            isCommitting = false
        }
    }
}

// MARK: - Verdict picker tag

/// A flat, `Picker`-friendly stand-in for the five cases of `KeyDecision`.
///
/// Presentation plumbing (see the type doc above), not a routing rule.
private enum DecisionKind: Hashable {
    case importAsLocal
    case linkToShared
    case moveToShared
    case leaveAlone
    case skip

    init(_ decision: KeyDecision) {
        switch decision {
        case .importAsLocal: self = .importAsLocal
        case .linkToShared: self = .linkToShared
        case .moveToShared: self = .moveToShared
        case .leaveAlone: self = .leaveAlone
        case .skip: self = .skip
        }
    }
}

/// Local copy of the shared-ID sanitize rules — the same rules
/// `PlainIngestPrompt`'s `sanitizeSharedID` applies at the CLI's ingest
/// prompt (`Sources/SharibakoCLI/Support/PlainIngestPrompt.swift`), mirrored
/// here rather than imported (`SharibakoCLI` is a closed executable target;
/// Do Not §1). Used only to pre-fill the "Move to shared" text field with a
/// plausible default — the user can still type anything;
/// `VaultCore.addSharedEntry` is the actual grammar gate at commit time. If
/// these ever diverge from `SharibakoCore`'s identifier rules, factor a
/// public helper on `SharibakoCore` (the CLI file's own standing note).
private func sanitizedSharedID(from raw: String) -> String {
    let lower = raw.lowercased()
    var mapped = ""
    for scalar in lower.unicodeScalars {
        let isLower = scalar.value >= 0x61 && scalar.value <= 0x7A
        let isDigit = scalar.value >= 0x30 && scalar.value <= 0x39
        let isDash = scalar.value == 0x2D
        if isLower || isDigit || isDash {
            mapped.unicodeScalars.append(scalar)
        } else {
            mapped.append("-")
        }
    }
    var collapsed = ""
    var lastWasDash = false
    for char in mapped {
        if char == "-" {
            if lastWasDash { continue }
            lastWasDash = true
        } else {
            lastWasDash = false
        }
        collapsed.append(char)
    }
    while collapsed.hasPrefix("-") { collapsed.removeFirst() }
    while collapsed.hasSuffix("-") { collapsed.removeLast() }
    return collapsed.isEmpty ? "scope" : collapsed
}
