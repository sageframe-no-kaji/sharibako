import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// ho-06.9 AT-02 tests: the reads and words the project-first views render
/// (`WorkshopModel+Pages.swift`) and the glyph tints (`Color+Theme.swift`).
///
/// The sidebar, header, and three status pages are coverage-excluded
/// declarative bodies; every count-aware phrase, fallback, and the
/// selection's load dispatch they rely on is specified here instead. Temp
/// vaults and temp scan roots only — no live user state, no Keychain.
@MainActor
@Suite("WorkshopModel Pages")
struct WorkshopModelPagesTests {
    // MARK: - The selected row

    @Test("selectedEntry and selectionTitle follow the selection and fall back when it vanishes")
    func selectedEntryAndTitle() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("falcon", type: .other, displayName: "Falcon Watch", in: vault)
            let model = ProjectsTestSupport.model(vault: vault)
            #expect(model.selectedEntry == nil)
            #expect(model.selectionTitle == "Projects")

            model.selection = .project(scopeID: "falcon")
            #expect(model.selectedEntry?.scopeID == "falcon")
            #expect(model.selectionTitle == "Falcon Watch")

            model.selection = .problem(markerPath: "/nowhere/.sharibako")
            #expect(model.selectedEntry == nil)
            #expect(model.selectionTitle == "Projects")
        }
    }

    // MARK: - Load dispatch

    @Test("loadContent loads a project's secrets and a folder's preview, and nothing for the rest")
    func loadContentDispatch() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("falcon", type: .other, in: vault)
            try Data([0x00]).write(to: vault.appendingPathComponent("scopes/falcon/API_KEY.age"))
            let root = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            let acme = root.appendingPathComponent("acme")
            try ProjectsTestSupport.writeEnv("STRIPE_SECRET_KEY=sk\n", in: acme)
            let model = ProjectsTestSupport.model(vault: vault)

            model.selection = .project(scopeID: "falcon")
            await model.loadContent(for: model.selection)
            #expect(model.secrets.map(\.key) == ["API_KEY"])
            #expect(model.candidatePreview == nil)

            model.selection = .candidate(directory: acme)
            await model.loadContent(for: model.selection)
            #expect(model.candidatePreview?.keys == ["STRIPE_SECRET_KEY"])
            #expect(model.secrets.isEmpty)

            for selection: WorkshopModel.Selection? in [
                .problem(markerPath: "/nowhere/.sharibako"), .shared(id: "anthropic"), nil,
            ] {
                model.selection = selection
                await model.loadContent(for: selection)
                #expect(model.secrets.isEmpty)
                #expect(model.candidatePreview == nil)
                #expect(model.errorMessage == nil)
            }
        }
    }

    // MARK: - Project header

    @Test("the header's drift clause counts lines for Out of date only")
    func headerDriftClause() {
        #expect(WorkshopModel.headerDriftClause(for: .outOfDate(keyCount: 1)) == "1 line differs")
        #expect(WorkshopModel.headerDriftClause(for: .outOfDate(keyCount: 3)) == "3 lines differ")
        #expect(WorkshopModel.headerDriftClause(for: .protected) == nil)
        #expect(WorkshopModel.headerDriftClause(for: .noFolderHere) == nil)
        #expect(WorkshopModel.headerDriftClause(for: .notProtected) == nil)
    }

    @Test("the header's location abbreviates the folder, says no folder, or stays silent when the status says it")
    func headerLocation() {
        let model = WorkshopModel(
            environment: ["SHARIBAKO_VAULT": "/nonexistent/vault"], home: URL(fileURLWithPath: "/Users/nobody"))
        let here = Self.entry(directory: URL(fileURLWithPath: "/Users/nobody/Projects/falcon"), status: .protected)
        #expect(model.headerLocation(for: here) == "~/Projects/falcon")
        let elsewhere = Self.entry(directory: URL(fileURLWithPath: "/opt/falcon"), status: .protected)
        #expect(model.headerLocation(for: elsewhere) == "/opt/falcon")
        let driftedNoFolder = Self.entry(directory: nil, status: .outOfDate(keyCount: 2))
        #expect(model.headerLocation(for: driftedNoFolder) == "No folder on this Mac")
        let away = Self.entry(directory: nil, status: .noFolderHere)
        #expect(model.headerLocation(for: away) == nil)
    }

    @Test("abbreviatedPath abbreviates under the injected home only")
    func abbreviatedPath() {
        let model = WorkshopModel(
            environment: ["SHARIBAKO_VAULT": "/nonexistent/vault"], home: URL(fileURLWithPath: "/Users/nobody"))
        #expect(model.abbreviatedPath(URL(fileURLWithPath: "/Users/nobody/a/b")) == "~/a/b")
        #expect(model.abbreviatedPath(URL(fileURLWithPath: "/Users/nobodyelse/a")) == "/Users/nobodyelse/a")
    }

    // MARK: - Counts and copy

    @Test("count lines are count-aware: the page's, the Protect sheet's, the first-run finish page's")
    func countLines() {
        #expect(WorkshopModel.envLineCount(0) == "No lines with a value in .env")
        #expect(WorkshopModel.envLineCount(1) == "1 line in .env")
        #expect(WorkshopModel.envLineCount(3) == "3 lines in .env")
        #expect(WorkshopModel.protectFoundCount(1) == "1 line found in .env")
        #expect(WorkshopModel.protectFoundCount(4) == "4 lines found in .env")
        #expect(
            WorkshopModel.firstRunCandidateSummary(count: 1)
                == "Found 1 project with a .env — it'll be waiting under Not protected.")
        #expect(
            WorkshopModel.firstRunCandidateSummary(count: 3)
                == "Found 3 projects with a .env — they'll be waiting under Not protected.")
    }

    @Test("the Problem page explains in the drawing's words, naming the project twice")
    func problemExplanation() {
        let paragraphs = WorkshopModel.problemExplanation(projectName: "ghost-project")
        #expect(
            paragraphs == [
                "This folder says it belongs to a project called ghost-project, but the vault has no "
                    + "project by that name. It may have been deleted, or the folder came from another machine.",
                "Protect this folder brings its .env into the vault as ghost-project. Forget this folder "
                    + "removes the claim file and leaves everything else alone.",
            ])
        #expect(WorkshopModel.unreadableClaimTitle == "Unreadable claim file")
        #expect(WorkshopModel.unreadableClaimLead.hasSuffix("in this folder:"))
    }

    @Test("the shared page counts distinct projects and lists each use as project (KEY)")
    func usedByHeadingAndLines() throws {
        try AppAgeKeyFixture.withEphemeralKey { fixture in
            try WorkshopTestSupport.withTempVault { vault in
                try WorkshopTestSupport.writeScope("nest", type: .other, in: vault)
                try WorkshopTestSupport.writeScope("falcon", type: .other, in: vault)
                let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
                try core.addSharedEntry("anthropic", value: "sk-shared")
                try core.addSharedEntry("openai", value: "sk-other")
                try core.addSharedEntry("solo", value: "sk-solo")
                try core.link("ANTHROPIC_API_KEY", inScope: "nest", toShared: "anthropic")
                try core.link("CLAUDE_KEY", inScope: "falcon", toShared: "anthropic")
                try core.link("ANTHROPIC_API_KEY", inScope: "falcon", toShared: "anthropic")
                try core.link("SOLO_KEY", inScope: "nest", toShared: "solo")

                let model = ProjectsTestSupport.model(vault: vault)

                #expect(model.usedByHeading(sharedID: "anthropic") == "Used by 2 projects:")
                #expect(
                    model.usedByLines(sharedID: "anthropic") == [
                        "falcon (ANTHROPIC_API_KEY)", "falcon (CLAUDE_KEY)", "nest (ANTHROPIC_API_KEY)",
                    ])
                #expect(model.usedByHeading(sharedID: "solo") == "Used by 1 project:")
                #expect(model.usedByHeading(sharedID: "openai") == "Not used by any project yet.")
                #expect(model.usedByLines(sharedID: "openai").isEmpty)
                #expect(WorkshopModel.sharedSecretNote.hasSuffix("Editing shared secrets arrives with linking."))
            }
        }
    }

    // MARK: - Row glyphs (Decision 8)

    @Test("each status's glyph wears its Decision 8 token")
    func statusGlyphPalettes() {
        let orphan = WorkshopModel.UnlinkedMarker.orphaned(
            scope: "ghost", markerURL: URL(fileURLWithPath: "/tmp/ghost/.sharibako"))
        #expect(WorkshopModel.ProjectStatus.notProtected.glyphPalette == Theme.inkSecondary)
        #expect(WorkshopModel.ProjectStatus.protected.glyphPalette == Theme.inSync)
        #expect(WorkshopModel.ProjectStatus.outOfDate(keyCount: 1).glyphPalette == Theme.alarm)
        #expect(WorkshopModel.ProjectStatus.problem(orphan).glyphPalette == Theme.alarm)
        #expect(WorkshopModel.ProjectStatus.noFolderHere.glyphPalette == Theme.inkTertiary)
    }

    @Test("a shared row wears link in inkSecondary and never its placeholder status")
    func sharedRowGlyph() {
        let shared = WorkshopModel.ProjectEntry(
            id: .shared(id: "anthropic"), name: "anthropic", directory: nil, scopeID: nil, status: .protected)
        #expect(shared.isShared)
        #expect(shared.glyphSymbolName == "link")
        #expect(shared.glyphPalette == Theme.inkSecondary)
        #expect(shared.glyphHelp.hasPrefix("Shared secret"))
        #expect(!shared.glyphHelp.contains("Protected"))
        #expect(shared.problemMarker == nil)

        let drifted = Self.entry(directory: nil, status: .outOfDate(keyCount: 2))
        #expect(!drifted.isShared)
        #expect(drifted.glyphSymbolName == "exclamationmark.triangle.fill")
        #expect(drifted.glyphPalette == Theme.alarm)
        #expect(drifted.glyphHelp == WorkshopModel.ProjectStatus.outOfDate(keyCount: 2).helpText)
    }

    @Test("problemMarker carries a Needs-attention row's claim file")
    func problemMarker() {
        let marker = WorkshopModel.UnlinkedMarker.failed(
            markerURL: URL(fileURLWithPath: "/tmp/broken/.sharibako"), reason: "bad yaml")
        let entry = WorkshopModel.ProjectEntry(
            id: .problem(markerPath: marker.markerPath),
            name: "Unreadable claim file",
            directory: URL(fileURLWithPath: "/tmp/broken"),
            scopeID: nil,
            status: .problem(marker)
        )
        #expect(entry.problemMarker == marker)
        #expect(entry.glyphSymbolName == "questionmark.circle")
    }

    // MARK: - Fixtures

    /// A `.project` row for header and glyph tests.
    private static func entry(directory: URL?, status: WorkshopModel.ProjectStatus) -> WorkshopModel.ProjectEntry {
        WorkshopModel.ProjectEntry(
            id: .project(scopeID: "falcon"), name: "falcon", directory: directory, scopeID: "falcon", status: status)
    }
}
