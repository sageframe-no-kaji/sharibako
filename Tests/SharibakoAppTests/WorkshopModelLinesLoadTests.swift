import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// ho-06.10 AT-02 tests for loading a page's lines (`WorkshopModel+Lines.swift`)
/// — a folder not yet protected, a fully and a half-protected project, a key
/// missing from `.env`, a project with no folder, an empty project, an
/// unreadable `.env`, a Problem folder — and for the choice setter with its
/// session flips and the `selectedSecretKey` shim.
///
/// Keyless throughout (`LinesTestSupport.writeVaultKey` writes bare key
/// files); temp vaults and roots only — no live user state, no Keychain.
@MainActor
@Suite("WorkshopModel Lines load")
struct WorkshopModelLinesLoadTests {
    // MARK: - Loading each kind of page

    @Test("a folder not yet protected: every line not protected or a setting, header counts the secrets")
    func candidateLines() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let root = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            let acme = root.appendingPathComponent("acme")
            try ProjectsTestSupport.writeEnv(
                "STRIPE_SECRET_KEY=sk_live_abc\nPORT=3000\nnot a line\nEMPTY=\nDB_PASSWORD=hunter2\n", in: acme)
            let model = ProjectsTestSupport.model(vault: vault)
            model.selection = .candidate(directory: acme)

            await model.loadContent(for: model.selection)

            #expect(model.isCandidate)
            #expect(model.projectLines.map(\.key) == ["STRIPE_SECRET_KEY", "DB_PASSWORD", "PORT"])
            #expect(model.secretLines.map(\.status) == [.notProtected, .notProtected])
            #expect(model.settingLines.map(\.key) == ["PORT"])
            #expect(model.projectLines.map(\.value) == ["sk_live_abc", "hunter2", "3000"])
            #expect(model.unprotectedSecretCount == 2)
            #expect(model.protectableLineCount == 2)
            #expect(model.headerState == .notProtected(count: 2))
            #expect(model.headerState.label == "Project not protected — 2 secrets in plain text")
            #expect(model.lineWarnings.count == 1)
            #expect(model.lineWarnings.first?.hasPrefix(".env line 3:") == true)
            #expect(model.errorMessage == nil)
        }
    }

    @Test("a fully protected project: every line protected, header Protected with the check's clause")
    func fullyProtectedLines() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("falcon", type: .other, in: vault)
            try LinesTestSupport.writeVaultKey("API_KEY", scope: "falcon", in: vault)
            try LinesTestSupport.writeVaultKey("PORT", scope: "falcon", in: vault)
            let root = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            let dir = try ProjectsTestSupport.seedMarker(scope: "falcon", under: root, named: "falcon")
            try ProjectsTestSupport.writeEnv("API_KEY=sk\nPORT=3000\n", in: dir)
            let model = ProjectsTestSupport.model(vault: vault)
            model.scanRoots = [root]
            await model.performLaunchScan()
            model.selection = .project(scopeID: "falcon")

            await model.loadContent(for: model.selection)

            #expect(!model.isCandidate)
            #expect(model.projectLines.map(\.status) == [.protected(kind: .value), .protected(kind: .value)])
            #expect(model.settingLines.isEmpty)
            #expect(model.protectableLineCount == 0)
            #expect(model.headerState == .protected(upToDate: nil))
            model.driftReports["falcon"] = ProjectsTestSupport.driftReport(scopeID: "falcon", drifted: 0)
            #expect(model.headerState == .protected(upToDate: true))
            model.driftReports["falcon"] = ProjectsTestSupport.driftReport(scopeID: "falcon", drifted: 2)
            #expect(model.headerState == .protected(upToDate: false, differing: 2))
            #expect(model.headerState.label == "Protected · 2 lines differ")
        }
    }

    @Test("a half-protected project with a key missing from .env shows all three secret statuses")
    func halfProtectedLines() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("nest", type: .other, in: vault)
            try LinesTestSupport.writeVaultKey("API_KEY", scope: "nest", in: vault)
            try LinesTestSupport.writeVaultKey("GONE_TOKEN", scope: "nest", in: vault)
            try LinesTestSupport.writeVaultKey("LINKED_KEY", scope: "nest", in: vault, link: "anthropic")
            let root = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            let dir = try ProjectsTestSupport.seedMarker(scope: "nest", under: root, named: "nest")
            try ProjectsTestSupport.writeEnv(
                "API_KEY=sk\nNEW_SECRET=s3cr3t-value-xyz\nLINKED_KEY=x\nDEBUG=true\n", in: dir)
            let model = ProjectsTestSupport.model(vault: vault)
            model.scanRoots = [root]
            await model.performLaunchScan()
            model.selection = .project(scopeID: "nest")

            await model.loadContent(for: model.selection)

            let byKey = Dictionary(uniqueKeysWithValues: model.projectLines.map { ($0.key, $0.status) })
            #expect(byKey["API_KEY"] == .protected(kind: .value))
            #expect(byKey["LINKED_KEY"] == .protected(kind: .link(sharedID: "anthropic")))
            #expect(byKey["NEW_SECRET"] == .notProtected)
            #expect(byKey["GONE_TOKEN"] == .missingFromEnv)
            #expect(byKey["DEBUG"] == .setting)
            #expect(model.headerState == .unprotected(count: 1))
            #expect(model.secretLines.last?.key == "GONE_TOKEN")
        }
    }

    @Test("a project with no folder on this Mac lists its vault keys as protected, nothing missing")
    func noFolderLines() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("chumon", type: .machine, in: vault)
            try LinesTestSupport.writeVaultKey("SSH_KEY", scope: "chumon", in: vault)
            let model = ProjectsTestSupport.model(vault: vault)
            model.selection = .project(scopeID: "chumon")

            await model.loadContent(for: model.selection)

            #expect(model.envRead == nil)
            #expect(model.projectLines.map(\.status) == [.protected(kind: .value)])
            #expect(model.headerState == .protected(upToDate: nil))
        }
    }

    @Test("an empty project and an empty folder have no lines")
    func emptyLines() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("blank", type: .other, in: vault)
            let model = ProjectsTestSupport.model(vault: vault)
            model.selection = .project(scopeID: "blank")
            await model.loadContent(for: model.selection)
            #expect(model.headerState == .empty)

            model.selection = .project(scopeID: "not a valid id")
            await model.loadContent(for: model.selection)
            #expect(model.projectLines.isEmpty)
            #expect(model.errorMessage == nil)
        }
    }

    @Test("an unreadable .env still shows the vault's keys and reports the failure")
    func unreadableEnvKeepsVaultKeys() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("odd", type: .other, in: vault)
            try LinesTestSupport.writeVaultKey("API_KEY", scope: "odd", in: vault)
            let root = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            let dir = try ProjectsTestSupport.seedMarker(scope: "odd", under: root, named: "odd")
            // `.env` as a directory: present, but unreadable as a file.
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent(".env"), withIntermediateDirectories: true)
            let model = ProjectsTestSupport.model(vault: vault)
            model.scanRoots = [root]
            await model.performLaunchScan()
            model.selection = .project(scopeID: "odd")

            await model.loadContent(for: model.selection)

            #expect(model.projectLines.map(\.key) == ["API_KEY"])
            #expect(model.errorMessage != nil)
        }
    }

    @Test("a Problem folder whose claim file names a missing project offers every line")
    func problemFolderLines() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let root = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            let dir = try ProjectsTestSupport.seedMarker(scope: "ghost", under: root, named: "ghost")
            try ProjectsTestSupport.writeEnv("API_KEY=sk\n", in: dir)
            let model = ProjectsTestSupport.model(vault: vault)
            model.scanRoots = [root]
            await model.performLaunchScan()
            let orphan = try #require(model.unlinkedMarkers.first)
            model.selection = .problem(markerPath: orphan.markerPath)

            await model.loadContent(for: model.selection)

            #expect(model.projectLines.map(\.status) == [.notProtected])
            #expect(model.orphanedClaim(markerPath: orphan.markerPath)?.scope == "ghost")
            #expect(model.orphanedClaim(markerPath: "/nowhere/.sharibako") == nil)
        }
    }

    @Test("a read for a row no longer selected is dropped; a shared page loads nothing")
    func staleReadDropped() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let root = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            let acme = root.appendingPathComponent("acme")
            try ProjectsTestSupport.writeEnv("A_TOKEN=1\n", in: acme)
            let model = ProjectsTestSupport.model(vault: vault)
            model.selection = .shared(id: "anthropic")

            await model.loadContent(for: .candidate(directory: acme))
            #expect(model.envRead == nil)

            await model.loadContent(for: model.selection)
            #expect(model.projectLines.isEmpty)
        }
    }

    // MARK: - Choices and selection

    @Test("a flip is remembered across selection changes, validated, and dropped when set back to default")
    func flipsPersistAndValidate() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try "ciphertext".write(
                to: vault.appendingPathComponent("shared/anthropic.age"), atomically: true, encoding: .utf8)
            let root = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            let acme = root.appendingPathComponent("acme")
            try ProjectsTestSupport.writeEnv("API_KEY=sk\nPORT=3000\n", in: acme)
            let model = ProjectsTestSupport.model(vault: vault)
            model.loadScopes()
            model.selection = .candidate(directory: acme)
            await model.loadContent(for: model.selection)

            model.setLineChoice(.useShared(id: "ghost"), forKey: "API_KEY")
            model.setLineChoice(.makeShared(id: "bad id"), forKey: "API_KEY")
            model.setLineChoice(.makeShared(id: "anthropic"), forKey: "API_KEY")
            model.setLineChoice(.protectLocal, forKey: "NOT_A_LINE")
            #expect(model.lineChoiceFlips.isEmpty)

            model.setLineChoice(.useShared(id: "anthropic"), forKey: "API_KEY")
            model.setLineChoice(.protectLocal, forKey: "PORT")
            #expect(model.projectLines.map(\.choice) == [.useShared(id: "anthropic"), .protectLocal])
            #expect(model.protectableLineCount == 2)

            model.selection = nil
            model.selection = .candidate(directory: acme)
            await model.loadContent(for: model.selection)
            #expect(model.projectLines.map(\.choice) == [.useShared(id: "anthropic"), .protectLocal])

            model.setLineChoice(.leaveAsSetting, forKey: "PORT")
            #expect(model.lineChoiceFlips.count == 1)
            model.setLineChoice(.makeShared(id: "api-key"), forKey: "API_KEY")
            #expect(model.selectedLine == nil)
            #expect(model.projectLines.first?.choice == .makeShared(id: "api-key"))

            model.clearLineChoices(for: acme)
            #expect(model.lineChoiceFlips.isEmpty)
        }
    }

    @Test("a line in the vault has no choice to set, and a page with no .env read ignores choices")
    func choiceIgnoredForVaultLines() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("falcon", type: .other, in: vault)
            try LinesTestSupport.writeVaultKey("API_KEY", scope: "falcon", in: vault)
            let root = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            let dir = try ProjectsTestSupport.seedMarker(scope: "falcon", under: root, named: "falcon")
            try ProjectsTestSupport.writeEnv("API_KEY=sk\n", in: dir)
            let model = ProjectsTestSupport.model(vault: vault)
            model.setLineChoice(.leaveAsSetting, forKey: "API_KEY")
            #expect(model.lineChoiceFlips.isEmpty)

            model.scanRoots = [root]
            await model.performLaunchScan()
            model.selection = .project(scopeID: "falcon")
            await model.loadContent(for: model.selection)
            model.setLineChoice(.leaveAsSetting, forKey: "API_KEY")

            #expect(model.lineChoiceFlips.isEmpty)
        }
    }

    @Test("the secret shim names only a line in the vault; a plaintext line is selected but not a secret")
    func selectedSecretKeyShim() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("nest", type: .other, in: vault)
            try LinesTestSupport.writeVaultKey("API_KEY", scope: "nest", in: vault)
            let root = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            let dir = try ProjectsTestSupport.seedMarker(scope: "nest", under: root, named: "nest")
            try ProjectsTestSupport.writeEnv("API_KEY=sk\nNEW_TOKEN=t-1\n", in: dir)
            let model = ProjectsTestSupport.model(vault: vault)
            model.scanRoots = [root]
            await model.performLaunchScan()
            model.selection = .project(scopeID: "nest")
            await model.loadContent(for: model.selection)

            model.selectedLineKey = "NEW_TOKEN"
            #expect(model.selectedSecretKey == nil)
            #expect(model.selectedLine?.status == .notProtected)

            model.selectedSecretKey = "API_KEY"
            #expect(model.selectedLineKey == "API_KEY")
            #expect(model.selectedSecretKey == "API_KEY")
            #expect(model.selectedLine?.status == .protected(kind: .value))
        }
    }
}
