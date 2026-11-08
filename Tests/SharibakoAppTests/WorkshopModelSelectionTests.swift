import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// ho-06.9 AT-01 tests: the one `selection` of four kinds, its re-masking
/// cascade (through `selection` and through the `selectedScopeID` shim), the
/// launch selection rule (pure, then applied by the launch scan), a Protect
/// commit pruning its folder and selecting the new project, and the keyless
/// candidate preview that lives and dies with a candidate selection.
///
/// Temp vaults and injected roots throughout; the commit fixture encrypts, so
/// it follows the encryption-test convention (`AppAgeKeyFixture`, `age` on
/// PATH) — no live user state, no Keychain.
@MainActor
@Suite("WorkshopModel Selection")
struct WorkshopModelSelectionTests {
    /// One entry with the given selection identity, for the pure launch-rule tests.
    private static func entry(_ id: WorkshopModel.Selection, named name: String) -> WorkshopModel.ProjectEntry {
        WorkshopModel.ProjectEntry(id: id, name: name, directory: nil, scopeID: nil, status: .protected)
    }

    /// Fills every field the cascade clears.
    private static func dirty(_ model: WorkshopModel) {
        model.selectedSecretKey = "DB"
        model.revealedValue = "plaintext"
        model.revealedNotes = "notes"
    }

    // MARK: - The cascade

    @Test("changing the selection re-masks: secret, revealed value and notes, and caches clear")
    func selectionCascade() throws {
        try WorkshopTestSupport.withTempVault { vault in
            let model = ProjectsTestSupport.model(vault: vault)
            model.selection = .project(scopeID: "alpha")
            Self.dirty(model)

            model.selection = .candidate(directory: URL(fileURLWithPath: "/tmp/acme"))

            #expect(model.selectedSecretKey == nil)
            #expect(model.revealedValue == nil)
            #expect(model.revealedNotes == nil)
            #expect(model.secrets.isEmpty)
            #expect(model.history.isEmpty)
            #expect(model.selectedScopeID == nil)
        }
    }

    @Test("re-selecting the same row keeps the selected secret")
    func sameSelectionKeepsState() throws {
        try WorkshopTestSupport.withTempVault { vault in
            let model = ProjectsTestSupport.model(vault: vault)
            model.selection = .shared(id: "anthropic")
            Self.dirty(model)

            model.selection = .shared(id: "anthropic")

            #expect(model.selectedSecretKey == "DB")
            #expect(model.revealedValue == "plaintext")
        }
    }

    @Test("the selectedScopeID shim reads and writes the .project selection and runs the cascade")
    func selectedScopeIDShim() throws {
        try WorkshopTestSupport.withTempVault { vault in
            let model = ProjectsTestSupport.model(vault: vault)
            model.selectedScopeID = "alpha"
            #expect(model.selection == .project(scopeID: "alpha"))
            Self.dirty(model)

            model.selectedScopeID = "beta"
            #expect(model.selection == .project(scopeID: "beta"))
            #expect(model.selectedSecretKey == nil)
            #expect(model.revealedValue == nil)

            model.selection = .problem(markerPath: "/tmp/ghost/.sharibako")
            #expect(model.selectedScopeID == nil)

            model.selectedScopeID = nil
            #expect(model.selection == nil)
        }
    }

    // MARK: - initialSelection (pure)

    @Test("initialSelection picks the first Not-protected row when there is one")
    func initialSelectionPrefersCandidates() {
        let acme = URL(fileURLWithPath: "/tmp/acme")
        let sections = [
            WorkshopModel.ProjectSection(
                id: .notProtected,
                entries: [
                    Self.entry(.candidate(directory: acme), named: "acme"),
                    Self.entry(.candidate(directory: URL(fileURLWithPath: "/tmp/bento")), named: "bento"),
                ]),
            WorkshopModel.ProjectSection(
                id: .projects, entries: [Self.entry(.project(scopeID: "falcon"), named: "falcon")]),
        ]
        #expect(WorkshopModel.initialSelection(sections: sections) == .candidate(directory: acme))
    }

    @Test("initialSelection falls back to the first project")
    func initialSelectionFallsBackToProject() {
        let sections = [
            WorkshopModel.ProjectSection(
                id: .projects,
                entries: [
                    Self.entry(.project(scopeID: "falcon"), named: "falcon"),
                    Self.entry(.project(scopeID: "nest"), named: "nest"),
                ]),
            WorkshopModel.ProjectSection(
                id: .sharedSecrets, entries: [Self.entry(.shared(id: "anthropic"), named: "anthropic")]),
        ]
        #expect(WorkshopModel.initialSelection(sections: sections) == .project(scopeID: "falcon"))
    }

    @Test("initialSelection selects nothing when only problems and shared secrets exist, or nothing at all")
    func initialSelectionNothing() {
        let sections = [
            WorkshopModel.ProjectSection(
                id: .needsAttention,
                entries: [Self.entry(.problem(markerPath: "/tmp/ghost/.sharibako"), named: "ghost")]),
            WorkshopModel.ProjectSection(
                id: .sharedSecrets, entries: [Self.entry(.shared(id: "anthropic"), named: "anthropic")]),
        ]
        #expect(WorkshopModel.initialSelection(sections: sections) == nil)
        #expect(WorkshopModel.initialSelection(sections: []) == nil)
    }

    // MARK: - Launch selection, applied

    @Test("the launch scan opens on the first Not-protected folder")
    func launchScanSelectsCandidate() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("falcon", type: .other, in: vault)
            let root = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            try ProjectsTestSupport.writeEnv("A=1\n", in: root.appendingPathComponent("bento"))
            try ProjectsTestSupport.writeEnv("B=2\n", in: root.appendingPathComponent("acme"))

            let model = ProjectsTestSupport.model(vault: vault)
            model.scanRoots = [root]
            await model.performLaunchScan()

            guard case .candidate(let directory) = model.selection else {
                Issue.record("Expected a candidate selection, got \(String(describing: model.selection))")
                return
            }
            #expect(directory.lastPathComponent == "acme")
        }
    }

    @Test("the launch scan opens on the first project when nothing needs protecting")
    func launchScanSelectsProject() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("nest", type: .other, in: vault)
            try WorkshopTestSupport.writeScope("falcon", type: .other, in: vault)
            let root = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }

            let model = ProjectsTestSupport.model(vault: vault)
            model.scanRoots = [root]
            await model.performLaunchScan()

            #expect(model.selection == .project(scopeID: "falcon"))
        }
    }

    @Test("with no scan roots the launch still opens on the first project")
    func launchWithoutRootsSelectsProject() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("falcon", type: .other, in: vault)
            let model = ProjectsTestSupport.model(vault: vault)
            #expect(model.scanRoots.isEmpty)

            await model.performLaunchScan()

            #expect(model.selection == .project(scopeID: "falcon"))
        }
    }

    @Test("the launch rule never overrides a selection and applies only once")
    func launchSelectionRespectsUserAndRunsOnce() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("falcon", type: .other, in: vault)
            try WorkshopTestSupport.writeScope("nest", type: .other, in: vault)
            let model = ProjectsTestSupport.model(vault: vault)
            model.selection = .project(scopeID: "nest")

            await model.performLaunchScan()
            #expect(model.selection == .project(scopeID: "nest"))

            model.selection = nil
            await model.performLaunchScan()
            #expect(model.selection == nil)
        }
    }

    @Test("a launch scan already in flight neither scans nor spends the launch rule")
    func busyLaunchScanSkipsRule() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("falcon", type: .other, in: vault)
            let model = ProjectsTestSupport.model(vault: vault)
            model.activity = .scanning
            await model.performLaunchScan()
            #expect(model.selection == nil)

            model.activity = nil
            await model.performLaunchScan()
            #expect(model.selection == .project(scopeID: "falcon"))
        }
    }

    // MARK: - Protect commit

    @Test("a Protect commit drops its folder from candidates and selects the new project")
    func commitPrunesCandidateAndSelects() async throws {
        try await AppAgeKeyFixture.withEphemeralKey { fixture in
            try await WorkshopTestSupport.withTempVault { vault in
                let root = try ProjectsTestSupport.makeRoot(near: vault)
                defer { try? FileManager.default.removeItem(at: root) }
                let bento = root.appendingPathComponent("bento")
                try ProjectsTestSupport.writeEnv("API_KEY=sk-live\n", in: bento)
                try ProjectsTestSupport.writeEnv("B=2\n", in: root.appendingPathComponent("obento"))

                let model = ProjectsTestSupport.model(vault: vault, ageKey: fixture.privateKeyURL)
                model.scanRoots = [root]
                await model.performLaunchScan()
                #expect(model.candidates.map(\.lastPathComponent) == ["bento", "obento"])
                #expect(model.selection == .candidate(directory: model.candidates[0]))

                // A trailing slash must not defeat the standardized-path prune.
                await model.beginIngest(directory: URL(fileURLWithPath: bento.path + "/"))
                await model.commitIngest()

                #expect(model.ingest.session == nil)
                #expect(model.candidates.map(\.lastPathComponent) == ["obento"])
                #expect(model.selection == .project(scopeID: "bento"))
                #expect(model.projectStatus(forScope: "bento") == .protected)
                #expect(model.projectSections.map(\.id) == [.notProtected, .projects])
            }
        }
    }

    // MARK: - Candidate preview

    @Test("the candidate preview lists every line with its value, class, and parse warnings")
    func candidatePreviewLines() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let root = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            let acme = root.appendingPathComponent("acme")
            try ProjectsTestSupport.writeEnv(
                "STRIPE_SECRET_KEY=sk_live_abc\nPORT=3000\nnot a line\nEMPTY=\n", in: acme)

            let model = ProjectsTestSupport.model(vault: vault)
            model.selection = .candidate(directory: acme)
            await model.loadCandidatePreview(for: acme)

            let preview = try #require(model.candidatePreview)
            #expect(preview.directory == acme)
            #expect(preview.keys == ["STRIPE_SECRET_KEY", "PORT"])
            #expect(preview.warnings.count == 1)
            #expect(preview.warnings.first?.hasPrefix(".env line 3:") == true)
            #expect(preview.lines.map(\.value) == ["sk_live_abc", "3000"])
            #expect(preview.lines[0].lineClass.isSecret)
            #expect(!preview.lines[1].lineClass.isSecret)
            #expect(preview.lines[0].classLabel.hasPrefix("secret — "))
            #expect(preview.lines[1].classLabel.hasPrefix("setting — "))
        }
    }

    @Test("a preview for a folder no longer selected is dropped, and selection clears it")
    func candidatePreviewFollowsSelection() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let root = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            let acme = root.appendingPathComponent("acme")
            try ProjectsTestSupport.writeEnv("A=1\n", in: acme)
            let bento = root.appendingPathComponent("bento")
            try ProjectsTestSupport.writeEnv("B=2\n", in: bento)

            let model = ProjectsTestSupport.model(vault: vault)
            await model.loadCandidatePreview(for: acme)
            #expect(model.candidatePreview == nil)  // nothing selected → dropped

            model.selection = .candidate(directory: bento)
            await model.loadCandidatePreview(for: acme)
            #expect(model.candidatePreview == nil)  // a different folder is selected

            await model.loadCandidatePreview(for: bento)
            #expect(model.candidatePreview?.keys == ["B"])

            model.selection = .candidate(directory: acme)
            #expect(model.candidatePreview == nil)
        }
    }

    @Test("a preview that cannot read the folder reports the failure")
    func candidatePreviewFailure() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let root = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            let odd = root.appendingPathComponent("odd")
            // `.env` as a directory: present, but unreadable as a file.
            try FileManager.default.createDirectory(
                at: odd.appendingPathComponent(".env"), withIntermediateDirectories: true)

            let model = ProjectsTestSupport.model(vault: vault)
            model.selection = .candidate(directory: odd)
            await model.loadCandidatePreview(for: odd)

            #expect(model.candidatePreview == nil)
            #expect(model.errorMessage != nil)
        }
    }
}
