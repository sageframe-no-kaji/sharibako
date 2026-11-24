import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// Fixture helpers shared by the ho-06.9 project-first suites.
///
/// Used by `WorkshopModelProjectsTests` and `WorkshopModelSelectionTests`:
/// temp scan roots beside a temp vault, claim files, malformed claim files,
/// and `.env` files. No live user state, no Keychain.
@MainActor
enum ProjectsTestSupport {
    /// A fresh temp scan root beside `vault`, removed by the caller's `defer`.
    static func makeRoot(near vault: URL) throws -> URL {
        let root = vault.deletingLastPathComponent().appendingPathComponent(
            "roots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Writes `contents` to `<directory>/.env`, creating `directory` first.
    static func writeEnv(_ contents: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try contents.write(
            to: directory.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    }

    /// Seeds a `.sharibako` under `root/<dirName>` naming `scope`; returns the
    /// project directory.
    @discardableResult
    static func seedMarker(scope: String, under root: URL, named dirName: String) throws -> URL {
        let projectDir = root.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try "scope: \(scope)\nmaterialize_to: .env\n".write(
            to: projectDir.appendingPathComponent(".sharibako"), atomically: true, encoding: .utf8)
        return projectDir
    }

    /// Seeds a malformed `.sharibako` (absolute `materialize_to`), which the
    /// scan reports as a failure rather than a marker.
    static func seedMalformedMarker(under root: URL, named dirName: String) throws {
        let projectDir = root.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try "scope: legit-scope\nmaterialize_to: /etc/passwd\n".write(
            to: projectDir.appendingPathComponent(".sharibako"), atomically: true, encoding: .utf8)
    }

    /// An open model over `vault` with an injected, nonexistent home.
    static func model(vault: URL, ageKey: URL? = nil) -> WorkshopModel {
        var environment = ["SHARIBAKO_VAULT": vault.path]
        if let ageKey {
            environment["SHARIBAKO_AGE_KEY"] = ageKey.path
        }
        return WorkshopModel(environment: environment, home: URL(fileURLWithPath: "/Users/nobody"))
    }

    /// A drift report for `scopeID` with `drifted` differing keys and one match.
    static func driftReport(scopeID: String, drifted: Int) -> DriftReport {
        let owned =
            [KeyDrift.match(key: "IN_SYNC")]
            + (0..<drifted).map { KeyDrift.fileMissing(key: "KEY_\($0)") }
        return DriftReport(
            scopeID: scopeID, path: URL(fileURLWithPath: "/tmp/.env"), owned: owned, parseWarnings: [])
    }
}

/// ho-06.9 AT-01 tests: `ProjectStatus`, the derived `projectSections`, the
/// candidates cache filled by the scan, the shared-secret caches, and Rescan's
/// reworded status line (the candidate preview is in
/// `WorkshopModelSelectionTests.swift` — it follows the selection).
///
/// Every status is built from a real fixture (temp vault, temp scan root,
/// claim files, `.env` files); the drift half is injected straight into
/// `driftReports`, the same seam the heal and guard suites use, since a
/// drift check needs a decrypt the derivation itself never does.
@MainActor
@Suite("WorkshopModel Projects")
struct WorkshopModelProjectsTests {
    // MARK: - ProjectStatus presentation

    @Test("each status has its own symbol, its status word, and a plain tooltip")
    func statusPresentation() {
        let orphan = WorkshopModel.UnlinkedMarker.orphaned(
            scope: "ghost", markerURL: URL(fileURLWithPath: "/tmp/ghost/.sharibako"))
        let failed = WorkshopModel.UnlinkedMarker.failed(
            markerURL: URL(fileURLWithPath: "/tmp/broken/.sharibako"), reason: "bad")
        let statuses: [WorkshopModel.ProjectStatus] = [
            .notProtected, .protected, .outOfDate(keyCount: 2), .problem(orphan), .noFolderHere,
        ]
        #expect(Set(statuses.map(\.symbolName)).count == 5)
        #expect(
            statuses.map(\.label) == [
                "Not protected", "Protected", "Out of date", "Problem", "No folder on this Mac",
            ])
        #expect(WorkshopModel.ProjectStatus.outOfDate(keyCount: 1).helpText.contains("1 secret in .env differs"))
        #expect(WorkshopModel.ProjectStatus.outOfDate(keyCount: 3).helpText.contains("3 secrets in .env differ"))
        #expect(WorkshopModel.ProjectStatus.problem(orphan).helpText.contains("ghost"))
        #expect(WorkshopModel.ProjectStatus.problem(failed).helpText.contains("can't be read"))
        #expect(WorkshopModel.ProjectStatus.problem(failed).symbolName == "questionmark.circle")
        for status in statuses + [.problem(failed)] {
            #expect(status.helpText.hasPrefix(status.label))
        }
    }

    // MARK: - Every status from fixtures, section order

    @Test("every status derives from its fixture, in the four sections' fixed order")
    func everyStatusAndSectionOrder() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("falcon", type: .projectDev, in: vault)
            try WorkshopTestSupport.writeScope("nest", type: .projectDev, in: vault)
            try WorkshopTestSupport.writeScope("chumon", type: .machine, in: vault)
            try "".write(
                to: vault.appendingPathComponent("shared/anthropic.age"), atomically: true, encoding: .utf8)
            let root = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            try ProjectsTestSupport.writeEnv("API_KEY=sk\n", in: root.appendingPathComponent("acme"))
            let falconDir = try ProjectsTestSupport.seedMarker(scope: "falcon", under: root, named: "falcon-dir")
            try ProjectsTestSupport.seedMarker(scope: "nest", under: root, named: "nest-dir")
            let ghostDir = try ProjectsTestSupport.seedMarker(scope: "ghost", under: root, named: "ghost-dir")
            try ProjectsTestSupport.seedMalformedMarker(under: root, named: "broken")

            let model = ProjectsTestSupport.model(vault: vault)
            model.scanRoots = [root]
            await model.performLaunchScan()
            model.driftReports["nest"] = ProjectsTestSupport.driftReport(scopeID: "nest", drifted: 2)

            let sections = model.projectSections
            #expect(sections.map(\.id) == [.notProtected, .projects, .needsAttention, .sharedSecrets])
            #expect(sections.map(\.title) == ["Not protected", "Projects", "Needs attention", "Shared secrets"])

            let notProtected = try #require(sections.first)
            #expect(notProtected.entries.map(\.name) == ["acme"])
            #expect(notProtected.entries.first?.status == .notProtected)
            #expect(notProtected.entries.first?.scopeID == nil)

            let projects = sections[1].entries
            #expect(projects.map(\.name) == ["chumon", "falcon", "nest"])
            #expect(projects.map(\.status) == [.noFolderHere, .protected, .outOfDate(keyCount: 2)])
            #expect(projects.map(\.id) == ["chumon", "falcon", "nest"].map { .project(scopeID: $0) })
            #expect(projects[0].directory == nil)
            #expect(projects[1].directory?.lastPathComponent == falconDir.lastPathComponent)

            let attention = sections[2].entries
            #expect(attention.map(\.name).sorted() == ["Unreadable claim file", "ghost"].sorted())
            let ghost = try #require(attention.first { $0.name == "ghost" })
            guard case .problem(.orphaned(let scope, _)) = ghost.status else {
                Issue.record("Expected an orphaned Problem, got \(ghost.status)")
                return
            }
            #expect(scope == "ghost")
            #expect(ghost.directory?.lastPathComponent == ghostDir.lastPathComponent)
            let broken = try #require(attention.first { $0.name == "Unreadable claim file" })
            guard case .problem(.failed) = broken.status else {
                Issue.record("Expected a failed Problem, got \(broken.status)")
                return
            }
            #expect(broken.directory?.lastPathComponent == "broken")

            #expect(sections[3].entries.map(\.id) == [.shared(id: "anthropic")])
            #expect(sections[3].entries.map(\.name) == ["anthropic"])
        }
    }

    @Test("empty sections are omitted; an empty vault yields no sections")
    func emptySectionsOmitted() throws {
        try WorkshopTestSupport.withTempVault { vault in
            let model = ProjectsTestSupport.model(vault: vault)
            #expect(model.projectSections.isEmpty)

            try WorkshopTestSupport.writeScope("solo", type: .other, in: vault)
            model.loadScopes()
            #expect(model.projectSections.map(\.id) == [.projects])
            #expect(model.projectSections.first?.entries.first?.status == .noFolderHere)
        }
    }

    @Test("projects sort by display name, falling back to the ID, case-insensitively")
    func projectsSortByName() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("zz-id", type: .other, displayName: "alpha", in: vault)
            try WorkshopTestSupport.writeScope("Beta", type: .other, in: vault)
            try WorkshopTestSupport.writeScope("aa-id", type: .other, displayName: "gamma", in: vault)
            try WorkshopTestSupport.writeScope("twin-b", type: .other, displayName: "twin", in: vault)
            try WorkshopTestSupport.writeScope("twin-a", type: .other, displayName: "twin", in: vault)
            let model = ProjectsTestSupport.model(vault: vault)
            let entries = try #require(model.projectSections.first).entries
            #expect(entries.map(\.name) == ["alpha", "Beta", "gamma", "twin", "twin"])
            #expect(entries.map(\.scopeID) == ["zz-id", "Beta", "aa-id", "twin-a", "twin-b"])
        }
    }

    @Test("a clean drift report leaves a project Protected; drift outranks a missing folder")
    func driftPrecedence() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("away", type: .other, in: vault)
            let model = ProjectsTestSupport.model(vault: vault)
            model.driftReports["away"] = ProjectsTestSupport.driftReport(scopeID: "away", drifted: 0)
            #expect(model.projectStatus(forScope: "away") == .noFolderHere)
            model.driftReports["away"] = ProjectsTestSupport.driftReport(scopeID: "away", drifted: 1)
            #expect(model.projectStatus(forScope: "away") == .outOfDate(keyCount: 1))
        }
    }

    @Test("projectEntry(for:) finds a current row and is nil for a vanished one")
    func projectEntryLookup() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("falcon", type: .other, displayName: "Falcon", in: vault)
            let model = ProjectsTestSupport.model(vault: vault)
            let entry = model.projectEntry(for: .project(scopeID: "falcon"))
            #expect(entry?.name == "Falcon")
            #expect(entry?.scopeID == "falcon")
            #expect(model.projectEntry(for: .project(scopeID: "gone")) == nil)
            #expect(model.projectEntry(for: .shared(id: "nope")) == nil)
        }
    }

    // MARK: - Candidates in the scan

    @Test("the launch scan fills candidates with unclaimed .env folders only")
    func launchScanFillsCandidates() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let root = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            try ProjectsTestSupport.writeEnv("A=1\n", in: root.appendingPathComponent("bento"))
            try ProjectsTestSupport.writeEnv("B=2\n", in: root.appendingPathComponent("obento"))
            let claimed = try ProjectsTestSupport.seedMarker(scope: "claimed", under: root, named: "claimed")
            try ProjectsTestSupport.writeEnv("C=3\n", in: claimed)

            let model = ProjectsTestSupport.model(vault: vault)
            #expect(model.candidates.isEmpty)
            model.scanRoots = [root]
            await model.performLaunchScan()

            #expect(model.candidates.map(\.lastPathComponent) == ["bento", "obento"])
            #expect(model.statusMessage == nil)  // the launch scan stays quiet
        }
    }

    @Test("rescan refills candidates and words the status line in projects")
    func rescanFillsCandidatesAndAnnounces() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("falcon", type: .other, in: vault)
            try WorkshopTestSupport.writeScope("away", type: .other, in: vault)
            let root = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            try ProjectsTestSupport.seedMarker(scope: "falcon", under: root, named: "falcon")
            try ProjectsTestSupport.seedMarker(scope: "ghost", under: root, named: "ghost")

            let model = ProjectsTestSupport.model(vault: vault)
            model.scanRoots = [root]
            await model.rescan()
            // The orphan is not "already protected"; only vault projects count.
            #expect(model.statusMessage == "Found no projects to protect; 1 already protected.")

            try ProjectsTestSupport.writeEnv("A=1\n", in: root.appendingPathComponent("acme"))
            try ProjectsTestSupport.writeEnv("B=2\n", in: root.appendingPathComponent("bento"))
            await model.rescan()
            #expect(model.candidates.map(\.lastPathComponent) == ["acme", "bento"])
            #expect(model.statusMessage == "Found 2 projects to protect; 1 already protected.")
        }
    }

    @Test("rescanSummary handles zero and one on both sides")
    func rescanSummaryWording() {
        #expect(
            WorkshopModel.rescanSummary(toProtect: 0, alreadyProtected: 4)
                == "Found no projects to protect; 4 already protected.")
        #expect(
            WorkshopModel.rescanSummary(toProtect: 1, alreadyProtected: 1)
                == "Found 1 project to protect; 1 already protected.")
        #expect(
            WorkshopModel.rescanSummary(toProtect: 3, alreadyProtected: 0)
                == "Found 3 projects to protect; none protected yet.")
    }

    @Test("rescan picks up roots added to config.yaml after launch")
    func rescanReloadsConfigRoots() async throws {
        try await WorkshopTestSupport.withTempDirectory { home in
            try await WorkshopTestSupport.withTempVault { vault in
                let root = try ProjectsTestSupport.makeRoot(near: vault)
                defer { try? FileManager.default.removeItem(at: root) }
                try ProjectsTestSupport.writeEnv("A=1\n", in: root.appendingPathComponent("bento"))

                let model = WorkshopModel(environment: ["SHARIBAKO_VAULT": vault.path], home: home)
                #expect(model.scanRoots.isEmpty)
                try WorkshopConfig.persistScanRoot(root, configURL: model.configURL)

                await model.rescan()

                #expect(model.scanRoots.map(\.path) == [root.path])
                #expect(model.statusMessage == "Found 1 project to protect; none protected yet.")
            }
        }
    }

    @Test("findUnboundCandidates skips claimed folders and dedupes overlapping roots")
    func findUnboundCandidatesFiltersAndDedupes() throws {
        try WorkshopTestSupport.withTempDirectory { base in
            try ProjectsTestSupport.writeEnv("A=1\n", in: base.appendingPathComponent("fresh"))
            let bound = base.appendingPathComponent("bound")
            try ProjectsTestSupport.writeEnv("B=2\n", in: bound)
            try "scope: bound\n".write(
                to: bound.appendingPathComponent(".sharibako"), atomically: true, encoding: .utf8)

            // The same root twice: overlap must not double-list `fresh`.
            let found = IngestCandidateScanner.findUnboundCandidates(under: [base, base])

            #expect(found.map(\.lastPathComponent) == ["fresh"])
        }
    }

    @Test("forgetting a folder's claim file brings its .env back under Not protected")
    func forgetRefillsCandidates() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let root = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            let ghost = try ProjectsTestSupport.seedMarker(scope: "ghost", under: root, named: "ghost")
            try ProjectsTestSupport.writeEnv("A=1\n", in: ghost)

            let model = ProjectsTestSupport.model(vault: vault)
            model.scanRoots = [root]
            await model.performLaunchScan()
            #expect(model.candidates.isEmpty)
            #expect(model.projectSections.map(\.id) == [.needsAttention])

            model.requestRemoveStrayMarker(try #require(model.unlinkedMarkers.first))
            await model.confirmRemoveStrayMarker()

            #expect(model.candidates.map(\.lastPathComponent) == ["ghost"])
            #expect(model.projectSections.map(\.id) == [.notProtected])
            #expect(model.statusMessage?.hasPrefix("Removed stray marker for 'ghost'") == true)
            #expect(model.activity == nil)
        }
    }

    // MARK: - Shared secrets and the link graph

    @Test("loadScopes loads shared IDs and the link graph; usedBy sorts by project")
    func sharedIDsAndUsedBy() throws {
        try AppAgeKeyFixture.withEphemeralKey { fixture in
            try WorkshopTestSupport.withTempVault { vault in
                try WorkshopTestSupport.writeScope("nest", type: .other, in: vault)
                try WorkshopTestSupport.writeScope("falcon", type: .other, in: vault)
                let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
                try core.addSharedEntry("anthropic", value: "sk-shared")
                try core.addSharedEntry("openai", value: "sk-other")
                try core.link("ANTHROPIC_API_KEY", inScope: "nest", toShared: "anthropic")
                try core.link("CLAUDE_KEY", inScope: "falcon", toShared: "anthropic")
                try core.link("ANTHROPIC_API_KEY", inScope: "falcon", toShared: "anthropic")

                let model = ProjectsTestSupport.model(vault: vault)

                #expect(model.sharedIDs == ["anthropic", "openai"])
                let used = model.usedBy(sharedID: "anthropic")
                #expect(used.map(\.scopeID) == ["falcon", "falcon", "nest"])
                #expect(used.map(\.key) == ["ANTHROPIC_API_KEY", "CLAUDE_KEY", "ANTHROPIC_API_KEY"])
                #expect(model.usedBy(sharedID: "openai").isEmpty)
                #expect(model.usedBy(sharedID: "unknown").isEmpty)
                #expect(model.linkGraph.count == 1)
                #expect(model.errorMessage == nil)
            }
        }
    }

    @Test("a damaged link file empties the shared caches but keeps the project list")
    func sharedLoadFailureKeepsScopes() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("falcon", type: .other, in: vault)
            try "".write(
                to: vault.appendingPathComponent("shared/anthropic.age"), atomically: true, encoding: .utf8)
            try "not a valid/id".write(
                to: vault.appendingPathComponent("scopes/falcon/KEY.link"), atomically: true, encoding: .utf8)

            let model = ProjectsTestSupport.model(vault: vault)

            #expect(model.scopes.map(\.identity) == ["falcon"])
            #expect(model.sharedIDs.isEmpty)
            #expect(model.linkGraph.isEmpty)
            #expect(model.errorMessage != nil)
        }
    }
}
