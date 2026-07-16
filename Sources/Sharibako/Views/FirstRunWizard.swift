import AppKit
import SwiftUI

/// The wizard rendered whenever `WorkshopModel.vaultState` is `.noVault`
/// (ho-06.3 Decision 1) — six ordered pages ending in a real vault: prereq
/// check, age key generate-or-import, a verified backup nudge, initial scan
/// root, an optional git remote, finish.
///
/// All branching logic lives in `WorkshopModel+FirstRun.swift` (tested);
/// this view reads ``WorkshopModel/firstRun`` and calls its intents (Required
/// Change 4, Do Not §5) — panel writes (the save/open panels) hand their
/// chosen `URL` straight to an intent rather than deciding anything
/// themselves. Calm pālana grounds throughout, no time bars or decoration
/// (Required Change 4) — plain-talk copy names the stakes.
///
/// Coverage-excluded: SwiftUI declarative body, not headlessly drivable
/// (ho-05 Decision 8) — see `.github/workflows/ci.yml`'s `EXCLUDED` regex.
struct FirstRunWizard: View {
    @Environment(WorkshopModel.self)
    private var model

    /// Where the vault will be created — `WorkshopWindow` passes the
    /// `.noVault(expectedPath:)` associated value straight through so the
    /// root and finish pages can state it plainly (Decision 3 — no chooser).
    let expectedPath: URL

    /// `true` while ``WorkshopModel/completeFirstRun()`` is in flight.
    ///
    /// Disables "Create Vault" against a double-tap. View-local UI state,
    /// not a branching decision (the `WorkshopWindow` status-pulse `@State`
    /// precedent).
    @State private var isCreating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                pageBody
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 520)
        .background(Color.ground)
    }

    @ViewBuilder private var pageBody: some View {
        switch model.firstRun.page {
        case .prereq: prereqPage
        case .key: keyPage
        case .backup: backupPage
        case .root: rootPage
        case .remote: remotePage
        case .finish: finishPage
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            Text("Set Up Sharibako")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.ink)
            Spacer()
            Text(
                "Step \(model.firstRun.page.rawValue + 1) of "
                    + "\(WorkshopModel.FirstRunPage.allCases.count)"
            )
            .font(.caption)
            .foregroundStyle(Color.inkTertiary)
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            if model.firstRun.page != .prereq {
                Button("Back") {
                    model.goToPreviousFirstRunPage()
                }
            }
            Spacer()
            if model.firstRun.page != .finish {
                Button("Continue") {
                    model.advanceFirstRunPage()
                }
                .disabled(!model.firstRunCanContinue)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    // MARK: - Page 1: Prereq

    private var prereqPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Before anything else, Sharibako needs age.")
                .font(.headline)
                .foregroundStyle(Color.ink)
            Text(
                "Sharibako encrypts every secret with age. Install it once and "
                    + "Sharibako takes it from there."
            )
            .foregroundStyle(Color.inkSecondary)
            if model.firstRun.prerequisitesOK {
                Label("age is installed.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.inSync)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Not found. Install it, then re-check:")
                        .foregroundStyle(Color.drift)
                    Text("brew install age")
                        .font(.system(.body, design: .monospaced))
                        .padding(8)
                        .background(Color.groundDeep)
                        .textSelection(.enabled)
                    Button("Re-check") {
                        model.checkFirstRunPrerequisites()
                    }
                }
            }
        }
        .task {
            model.checkFirstRunPrerequisites()
        }
    }

    // MARK: - Page 2: Key

    private var keyPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch model.firstRun.keyMode {
            case .existingKeyFound:
                Label("You already have a key.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.inSync)
                Text("Sharibako found an existing age key in the Keychain and will use it.")
                    .foregroundStyle(Color.inkSecondary)
            case .notChosen, .generated, .imported:
                Text("Every secret in your vault is encrypted to one age key.")
                    .font(.headline)
                    .foregroundStyle(Color.ink)
                Text("Lose the key, lose the vault — the next page guides you through a backup.")
                    .foregroundStyle(Color.inkSecondary)
                HStack(spacing: 12) {
                    Button("Generate a New Key") {
                        model.generateFirstRunKey()
                    }
                    Button("Import Existing Key…") {
                        importExistingKey()
                    }
                }
            }
            if let message = model.firstRun.errorMessage {
                Text(message).foregroundStyle(Color.drift)
            }
        }
        .task {
            if model.firstRun.keyMode == .notChosen {
                model.checkExistingKeychainKey()
            }
        }
    }

    private func importExistingKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose your age identity file"
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.importFirstRunKey(from: url)
    }

    // MARK: - Page 3: Backup

    private var backupPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Back up your key before you go further.")
                .font(.headline)
                .foregroundStyle(Color.ink)
            Text(
                "Lose this key and every secret in the vault is unrecoverable — "
                    + "no reset, no support ticket, nothing."
            )
            .foregroundStyle(Color.drift)
            if let pending = model.firstRun.pendingBackup {
                Text("Recipient: \(pending.recipient)")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            Button("Save Backup File…") {
                saveBackup()
            }
            if model.firstRun.backupVerified {
                Label("Backup verified.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.inSync)
            }
            if let message = model.firstRun.errorMessage {
                Text(message).foregroundStyle(Color.drift)
            }
        }
    }

    private func saveBackup() {
        guard let pending = model.firstRun.pendingBackup else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "sharibako-key-backup.txt"
        panel.message = "Save your age key backup somewhere safe"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard (try? pending.identity.write(to: url, atomically: true, encoding: .utf8)) != nil
        else { return }
        model.verifyFirstRunBackup(at: url)
    }

    // MARK: - Page 4: Root

    private var rootPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Where do you keep your code?")
                .font(.headline)
                .foregroundStyle(Color.ink)
            Text("Sharibako scans here for .env-bearing projects.")
                .foregroundStyle(Color.inkSecondary)
            if let root = model.firstRun.scanRoot {
                Text(root.path)
                    .font(.system(.body, design: .monospaced))
            } else {
                Text("No likely folder found — choose one.")
                    .foregroundStyle(Color.drift)
            }
            Button("Choose a Different Folder…") {
                chooseScanRoot()
            }
            Divider()
            Text("Your vault will live at \(expectedPath.path).")
                .font(.caption)
                .foregroundStyle(Color.inkTertiary)
        }
        .task {
            if model.firstRun.scanRoot == nil {
                model.suggestFirstRunScanRoot(home: model.home)
            }
        }
    }

    private func chooseScanRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a directory to scan for .sharibako markers"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.setFirstRunScanRootOverride(url)
    }

    // MARK: - Page 5: Remote

    private var remotePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Back this vault up to a git remote (optional).")
                .font(.headline)
                .foregroundStyle(Color.ink)
            Text("The remote is the vault's real backup — leave this blank to skip for now.")
                .foregroundStyle(Color.inkSecondary)
            TextField("git@host:path or https://…", text: remoteURLBinding)
                .textFieldStyle(.roundedBorder)
            if let error = model.firstRun.remoteURLError {
                Text(error).foregroundStyle(Color.drift)
            }
        }
    }

    private var remoteURLBinding: Binding<String> {
        Binding(
            get: { model.firstRun.remoteURLText },
            set: { model.setFirstRunRemoteURL($0) }
        )
    }

    // MARK: - Page 6: Finish

    private var finishPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ready to create your vault.")
                .font(.headline)
                .foregroundStyle(Color.ink)
            Text(expectedPath.path)
                .font(.system(.body, design: .monospaced))
            if let root = model.firstRun.scanRoot {
                Text("Scanning: \(root.path)")
                    .foregroundStyle(Color.inkSecondary)
            }
            if let error = model.firstRun.remoteURLError {
                Text(error).foregroundStyle(Color.drift)
            }
            if let error = model.firstRun.errorMessage {
                Text(error).foregroundStyle(Color.drift)
            }
            Button(isCreating ? "Creating…" : "Create Vault") {
                createVault()
            }
            .disabled(isCreating)
        }
    }

    private func createVault() {
        isCreating = true
        Task {
            await model.completeFirstRun()
            isCreating = false
        }
    }
}
