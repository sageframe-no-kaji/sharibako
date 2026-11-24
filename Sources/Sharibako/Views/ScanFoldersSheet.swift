import AppKit
import SwiftUI

/// The Scan folders… sheet (ho-06.10 Decision 8, AT-04): the folders
/// searched for projects, each with its full path and a Remove, and Add….
///
/// Presented while `model.isScanFoldersSheetPresented`. Add… asks for a
/// folder (`NSOpenPanel`, directories only) and hands it to
/// ``WorkshopModel/addScanFolder(_:)``; Remove routes to
/// ``WorkshopModel/removeScanFolder(_:)``; both persist to `config.yaml`.
/// Done — or any dismissal — runs ``WorkshopModel/closeScanFolders()``,
/// which rescans over the new list; the sidebar footer reflects it. Every
/// word and rule is a `WorkshopModel` read (`WorkshopModel+VaultSettings.swift`,
/// tested).
///
/// Coverage-excluded: SwiftUI declarative body and an `NSOpenPanel`, not
/// headlessly drivable (ho-05 Decision 8) — same justification as
/// `EnvPreviewSheet`.
struct ScanFoldersSheet: View {
    @Environment(WorkshopModel.self)
    private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Scan folders")
                    .font(.headline)
                Text("Sharibako looks for projects in these folders. Rescan runs when you close this.")
                    .font(.callout)
                    .foregroundStyle(Color.inkSecondary)
            }

            if model.scanRoots.isEmpty {
                Text(WorkshopModel.noScanFoldersText)
                    .foregroundStyle(Color.inkSecondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.scanRoots, id: \.self) { root in
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .foregroundStyle(Color.inkSecondary)
                            Text(root.path)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(Color.ink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .help(root.path)
                            Spacer(minLength: 8)
                            Button("Remove") {
                                model.removeScanFolder(root)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Color.drift)
                            .help("Stop scanning \(root.path) — nothing in it is changed")
                        }
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
                .padding(.horizontal, 10)
                .background(Color.panelGround)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.message = "Choose a folder where you keep your projects"
                    panel.prompt = "Add"
                    guard panel.runModal() == .OK, let folder = panel.url else { return }
                    model.addScanFolder(folder)
                } label: {
                    Label("Add…", systemImage: "plus")
                }
                Spacer()
                Button("Done") {
                    Task { await model.closeScanFolders() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 520)
        // Flat pālana ground (ho-06.5 Decision 3).
        .background(Color.ground)
    }
}
