import SwiftUI

/// Parts shared by the content column's pages (ho-06.9 AT-02, moved here by
/// ho-06.10 AT-03 when the Not-protected page went): the title block, the
/// quiet Open in Finder link, the pane-local error, and the shared-secret
/// form the page's rows and the detail pane both open, presented as the
/// window's sheet (ho-06.10 AT-05).
///
/// Every string comes from `WorkshopModel` (tested); these views only lay
/// them out.
///
/// Coverage-excluded: SwiftUI declarative bodies, not headlessly drivable
/// (ho-05 Decision 8).

/// A page's title block.
///
/// The row's name, its status word beneath when `showsStatus` (the project
/// page's header says where it stands instead), and the folder's path —
/// abbreviated and middle-truncated, the full path in the tooltip — or "No
/// folder on this Mac". Shared by the project and Problem pages.
struct PageTitle: View {
    /// The row the page is for; its name and status word head the page.
    let entry: WorkshopModel.ProjectEntry
    /// The folder the row stands for, when it has one on this Mac.
    let directory: URL?
    /// Whether the row's status word shows under its name.
    var showsStatus = true

    @Environment(WorkshopModel.self)
    private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.name)
                .font(.title2)
                .foregroundStyle(Color.ink)
                .textSelection(.enabled)
            if showsStatus {
                Text(entry.status.label)
                    .foregroundStyle(Color.inkSecondary)
            }
            Text(model.pageLocation(for: directory))
                .font(.callout)
                .foregroundStyle(Color.inkTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(directory?.path ?? model.pageLocation(for: nil))
        }
    }
}

/// The quiet "Open in Finder" link under a status page's verbs, through the
/// shared ``WorkshopModel/openInFinder(_:)`` helper (it announces).
struct OpenInFinderLink: View {
    /// The folder to open.
    let directory: URL

    @Environment(WorkshopModel.self)
    private var model

    var body: some View {
        Button {
            model.openInFinder(directory)
        } label: {
            Label("Open in Finder", systemImage: "folder")
        }
        .buttonStyle(.link)
        .foregroundStyle(Color.inkSecondary)
        .help("Open \(directory.path) in Finder")
    }
}

/// A failure from this pane's action, rendered where the action was
/// (ho-06.10 Decision 8): the message in the rust alarm, the next step
/// beneath in `inkSecondary`.
struct PaneErrorView: View {
    /// The failure to show.
    let error: WorkshopModel.PaneError

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(error.message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.drift)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let nextStep = error.nextStep {
                Text(nextStep)
                    .font(.callout)
                    .foregroundStyle(Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The shared-secret form on a protected line, as the window's sheet.
///
/// Whichever door opened it — the line's right-click menu or the detail
/// pane's button — and never inline beneath the detail pane's sections.
///
/// Presented by `WorkshopWindow` on the window, outside the
/// `NavigationSplitView`, while ``WorkshopModel/isLineShareFormPresented``.
/// It replaced a popover anchored to the line's `List` row (ho-06.10 AT-05):
/// after that popover's Make it a shared secret failed (the key in use could
/// not read the project's secrets), the gate saw the whole split view go
/// blank while the model kept its selection and lines. A sheet hangs off no
/// view inside the split view, so nothing the failure re-renders there can
/// take its anchor away.
///
/// **Make it a shared secret**: the name field, starting on the suggested
/// name. **Use shared secret…**: the picker of the vault's shared secrets.
/// Beneath either, the validation note — what is wrong with the entry, in
/// the alarm token, or what the one button will do — then Cancel and the
/// one button. Cancel or Escape closes it with nothing done; a submit closes
/// it whatever the outcome, and a failure shows in the pane beneath.
///
/// Every word and rule is a `WorkshopModel` read or intent
/// (`WorkshopModel+Verbs.swift`, tested); this view only lays them out.
///
/// Coverage-excluded: SwiftUI declarative body, not headlessly drivable
/// (ho-05 Decision 8).
struct LineShareSheet: View {
    @Environment(WorkshopModel.self)
    private var model

    var body: some View {
        if let form = model.lineShareForm {
            VStack(alignment: .leading, spacing: 10) {
                Text(form.key)
                    .font(.headline.monospaced())
                    .foregroundStyle(Color.ink)
                switch form.kind {
                case .useShared:
                    Picker("Shared secret", selection: sharedIDBinding) {
                        ForEach(model.sharedIDs, id: \.self) { id in
                            Text(id)
                                .tag(id)
                        }
                    }
                    .fixedSize()
                case .makeShared:
                    TextField("Shared secret name", text: sharedIDBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit(submit)
                }
                if let problem = model.lineShareFormProblem {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(Color.drift)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(WorkshopModel.lineShareFormHint(form.kind))
                        .font(.callout)
                        .foregroundStyle(Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Cancel") {
                        model.cancelLineShareForm()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button(WorkshopModel.lineShareFormAction(form.kind), action: submit)
                        .primaryActionButton()
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.lineShareFormProblem != nil || model.activity != nil)
                }
            }
            .padding()
            .frame(width: 360)
            // Flat pālana ground (ho-06.5 Decision 3).
            .background(Color.ground)
        }
    }

    /// Submits the form when its entry is valid.
    private func submit() {
        guard model.lineShareFormProblem == nil, model.activity == nil else { return }
        model.submitLineShareForm()
    }

    /// The form's shared-secret ID, read from and written to the model.
    private var sharedIDBinding: Binding<String> {
        Binding(
            get: { model.lineShareForm?.sharedID ?? "" },
            set: { model.lineShareForm?.sharedID = $0 }
        )
    }
}
