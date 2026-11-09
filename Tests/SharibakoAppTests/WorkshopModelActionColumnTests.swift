import Foundation
import Testing

@testable import Sharibako

/// ho-06.9 AT-03 tests: the action column's reads (Decision 7) —
/// ``WorkshopModel/selectionVerbs`` per kind of row, the disabled reasons and
/// tooltips (``WorkshopModel/writeDisabledReason``), the VAULT gate
/// ``WorkshopModel/hasOutOfDateProjects``, and the New… menu's secret title.
///
/// `ActionPanel` is a coverage-excluded declarative body; what it shows and
/// when each verb is enabled is specified here instead. Fixtures from
/// `ProjectsTestSupport` (temp vault, temp scan root, claim files, `.env`
/// files); the drift half is injected into `driftReports`. No live user
/// state, no Keychain.
@MainActor
@Suite("WorkshopModel action column")
struct WorkshopModelActionColumnTests {
    // MARK: - Fixtures

    /// Runs `body` with a model over every row kind, and its scan root.
    ///
    /// The rows: `acme` (Not protected), `falcon` (Protected), `nest` (Out of
    /// date), `chumon` (No folder here), `ghost` (orphaned Problem), `broken`
    /// (unreadable Problem), and the shared secret `anthropic`.
    private static func withEveryRowKind(
        _ body: (WorkshopModel, URL) async throws -> Void
    ) async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("falcon", type: .projectDev, displayName: "Falcon", in: vault)
            try WorkshopTestSupport.writeScope("nest", type: .projectDev, in: vault)
            try WorkshopTestSupport.writeScope("chumon", type: .machine, in: vault)
            try "".write(
                to: vault.appendingPathComponent("shared/anthropic.age"), atomically: true, encoding: .utf8)
            let root = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            try ProjectsTestSupport.writeEnv("API_KEY=sk\n", in: root.appendingPathComponent("acme"))
            try ProjectsTestSupport.seedMarker(scope: "falcon", under: root, named: "falcon-dir")
            try ProjectsTestSupport.seedMarker(scope: "nest", under: root, named: "nest-dir")
            try ProjectsTestSupport.seedMarker(scope: "ghost", under: root, named: "ghost-dir")
            try ProjectsTestSupport.seedMalformedMarker(under: root, named: "broken")

            let model = ProjectsTestSupport.model(vault: vault)
            model.scanRoots = [root]
            await model.performLaunchScan()
            model.driftReports["nest"] = ProjectsTestSupport.driftReport(scopeID: "nest", drifted: 1)
            try await body(model, root)
        }
    }

    /// The selection of the Needs-attention row named `name`.
    private static func problem(named name: String, in model: WorkshopModel) throws -> WorkshopModel.Selection {
        let entries = model.projectSections.flatMap(\.entries)
        return try #require(entries.first { $0.name == name && $0.problemMarker != nil }).id
    }

    @Test("the selection group lists exactly Decision 7's verbs for each kind of row")
    func selectionVerbsPerKind() async throws {
        try await Self.withEveryRowKind { model, root in
            model.selection = nil
            #expect(model.selectionVerbs.isEmpty)

            model.selection = .candidate(directory: root.appendingPathComponent("acme"))
            #expect(model.selectionVerbs == [.protect, .openInFinder])

            for scopeID in ["falcon", "nest", "chumon"] {
                model.selection = .project(scopeID: scopeID)
                #expect(model.selectionVerbs == [.writeEnv, .previewEnv, .openInFinder, .unprotect, .deleteProject])
            }

            model.selection = try Self.problem(named: "ghost", in: model)
            #expect(model.selectionVerbs == [.protectFolder, .forgetFolder, .openInFinder])

            model.selection = try Self.problem(named: "Unreadable claim file", in: model)
            #expect(model.selectionVerbs == [.openInFinder])

            model.selection = .shared(id: "anthropic")
            #expect(model.selectionVerbs.isEmpty)

            model.selection = .project(scopeID: "gone")
            #expect(model.selectionVerbs.isEmpty)
        }
    }

    @Test("Write, Preview, and Open are disabled with the reason for a project with no folder here")
    func writeDisabledReasons() async throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("away", type: .machine, in: vault)
            let cold = ProjectsTestSupport.model(vault: vault)
            #expect(cold.writeDisabledReason == "Select a project first")
            cold.selection = .project(scopeID: "away")
            #expect(cold.writeDisabledReason == "Not scanned yet — rescan to find this project's folder")
        }
        try await Self.withEveryRowKind { model, root in
            model.selection = .project(scopeID: "chumon")
            #expect(model.writeDisabledReason == WorkshopModel.noFolderHereReason)
            #expect(WorkshopModel.noFolderHereReason == "No folder on this Mac — attach one in a later version")
            for verb in [WorkshopModel.SelectionVerb.writeEnv, .previewEnv, .openInFinder] {
                #expect(model.disabledReason(for: verb) == WorkshopModel.noFolderHereReason)
                #expect(model.help(for: verb) == WorkshopModel.noFolderHereReason)
            }
            #expect(model.disabledReason(for: .deleteProject) == nil)

            for scopeID in ["falcon", "nest"] {
                model.selection = .project(scopeID: scopeID)
                #expect(model.writeDisabledReason == nil)
                #expect(model.selectionVerbs.allSatisfy { model.disabledReason(for: $0) == nil })
            }

            model.selection = .candidate(directory: root.appendingPathComponent("acme"))
            #expect(model.selectionVerbs.allSatisfy { model.disabledReason(for: $0) == nil })
            model.selection = try Self.problem(named: "ghost", in: model)
            #expect(model.selectionVerbs.allSatisfy { model.disabledReason(for: $0) == nil })
            model.selection = try Self.problem(named: "Unreadable claim file", in: model)
            #expect(model.disabledReason(for: .openInFinder) == nil)
        }
    }

    @Test("verb titles, symbols, rust, and tooltips speak the ten words")
    func verbPresentation() async throws {
        #expect(
            WorkshopModel.SelectionVerb.allCases.map(\.title) == [
                "Protect", "Write .env", "Preview .env", "Open in Finder", "Unprotect", "Delete project",
                "Protect this folder", "Forget this folder",
            ])
        #expect(
            WorkshopModel.SelectionVerb.allCases.filter(\.isDestructive) == [.unprotect, .deleteProject, .forgetFolder])
        #expect(WorkshopModel.SelectionVerb.allCases.allSatisfy { !$0.systemImage.isEmpty && $0.id == $0 })

        let retired = ["scope", "marker", "materialize", "ingest", "drift", "reconcile", "orphan", "stale"]
        try await Self.withEveryRowKind { model, root in
            let ghost = try Self.problem(named: "ghost", in: model)
            var texts =
                WorkshopModel.SelectionVerb.allCases.map(\.title) + [
                    WorkshopModel.noFolderHereReason, WorkshopModel.noFolderToUnprotectReason,
                ]
            for selection: WorkshopModel.Selection? in [
                nil, .candidate(directory: root.appendingPathComponent("acme")), .project(scopeID: "falcon"),
                .project(scopeID: "chumon"), ghost,
            ] {
                model.selection = selection
                texts += WorkshopModel.SelectionVerb.allCases.map { model.help(for: $0) }
                texts += [model.writeDisabledReason, model.newSecretMenuTitle].compactMap(\.self)
            }
            for text in texts {
                #expect(!retired.contains { text.lowercased().contains($0) }, "retired word in: \(text)")
            }

            model.selection = ghost
            #expect(model.help(for: .protectFolder) == "Bring this folder's .env into the vault as ghost")
            model.selection = nil
            #expect(model.help(for: .protectFolder) == "Bring this folder's .env into the vault as its project")
        }
    }

    @Test("Write all out of date waits for a check that finds something")
    func hasOutOfDateProjects() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("falcon", type: .other, in: vault)
            let model = ProjectsTestSupport.model(vault: vault)
            #expect(!model.hasOutOfDateProjects)
            model.driftReports["falcon"] = ProjectsTestSupport.driftReport(scopeID: "falcon", drifted: 0)
            #expect(!model.hasOutOfDateProjects)
            model.driftReports["falcon"] = ProjectsTestSupport.driftReport(scopeID: "falcon", drifted: 2)
            #expect(model.hasOutOfDateProjects)
        }
    }

    @Test("the New… menu's secret item names the selected project, or stays plain")
    func newSecretMenuTitle() async throws {
        try await Self.withEveryRowKind { model, root in
            #expect(model.newSecretMenuTitle == "Secret")
            model.selection = .project(scopeID: "falcon")
            #expect(model.newSecretMenuTitle == "Secret in Falcon")
            model.selection = .project(scopeID: "chumon")
            #expect(model.newSecretMenuTitle == "Secret in chumon")
            model.selection = .candidate(directory: root.appendingPathComponent("acme"))
            #expect(model.newSecretMenuTitle == "Secret")
            model.selection = .shared(id: "anthropic")
            #expect(model.newSecretMenuTitle == "Secret")
        }
    }
}
