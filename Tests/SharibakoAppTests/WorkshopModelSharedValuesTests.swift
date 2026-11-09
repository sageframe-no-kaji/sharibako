import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// ho-06.10 AT-05 tests for the shared-value question at Protect time
/// (`WorkshopModel+SharedValues.swift`): a line protected for its project
/// whose value equals a shared secret's is held back and asked about, and
/// either answer commits correctly.
///
/// The commit fixtures encrypt, so they follow the encryption-test convention
/// (`AppAgeKeyFixture`, `age`/`age-keygen` on PATH, the file-key dev seam).
@MainActor
@Suite("WorkshopModel Shared values at Protect")
struct WorkshopModelSharedValuesTests {
    // MARK: - Shared values at Protect time

    @Test("protecting a line with a shared secret's value asks first, and Use the shared secrets links it")
    func protectLineAsksThenLinks() async throws {
        try await GateFixesTestSupport.withCandidates(
            ["app": "OPENAI_API_KEY=sk-same\nOTHER_KEY=sk-own\n"], shared: ["openai-api-key": "sk-same"]
        ) { model, vault, _, fixture in
            await model.protectLine(key: "OPENAI_API_KEY")

            #expect(try VaultCore(vaultURL: vault).listScopes().isEmpty)
            let held = try #require(model.presentedSharedValueMatches)
            #expect(held.matches == [.init(key: "OPENAI_API_KEY", sharedID: "openai-api-key")])
            #expect(held.origin == .line(key: "OPENAI_API_KEY"))
            #expect(WorkshopModel.sharedValueMatchesTitle == "Some values are already shared secrets")
            #expect(
                WorkshopModel.sharedValueMatchesMessage(for: held)
                    == "OPENAI_API_KEY has the same value as the shared secret openai-api-key")
            #expect(WorkshopModel.useSharedSecretsButton == "Use the shared secrets")
            #expect(WorkshopModel.protectSeparatelyButton == "Protect separately")

            let taken = try #require(model.takeSharedValueMatches())
            #expect(model.activity == .ingesting)
            #expect(model.presentedSharedValueMatches == nil)
            #expect(model.takeSharedValueMatches() == nil)
            await model.answerSharedValueMatches(taken, useShared: true)

            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            #expect(try core.inspect("app").map(\.kind) == [.link(sharedID: "openai-api-key")])
            #expect(model.selection == .project(scopeID: "app"))
            #expect(model.selectedLineKey == "OPENAI_API_KEY")
            #expect(model.statusMessage == "Protected 1 secret in app.")
            #expect(model.pendingSharedValueMatches.isEmpty)
            #expect(model.activity == nil)
        }
    }

    @Test("Protect separately commits the page as planned, each line with its own value")
    func protectPageSeparately() async throws {
        try await GateFixesTestSupport.withCandidates(
            ["app": "OPENAI_API_KEY=sk-same\nOTHER_KEY=sk-own\nPORT=1\n"], shared: ["openai-api-key": "sk-same"]
        ) { model, vault, _, fixture in
            await model.protectRecommended()
            let held = try #require(model.takeSharedValueMatches())
            #expect(held.origin == .page)
            #expect(held.matches.map(\.key) == ["OPENAI_API_KEY"])

            await model.answerSharedValueMatches(held, useShared: false)

            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            #expect(try core.getValue("OPENAI_API_KEY", inScope: "app") == "sk-same")
            #expect(try core.inspect("app").map(\.kind) == [.value, .value])
            #expect(model.statusMessage == "Protected 2 secrets in app; 1 setting left in .env.")
        }
    }

    @Test("Cancel drops the question and protects nothing; a line using a shared secret is never asked about")
    func cancelAndNoQuestion() async throws {
        try await GateFixesTestSupport.withCandidates(
            ["app": "OPENAI_API_KEY=sk-same\n"], shared: ["openai-api-key": "sk-same"]
        ) { model, vault, _, fixture in
            await model.protectRecommended()
            #expect(model.pendingSharedValueMatches.count == 1)
            model.cancelSharedValueMatches()
            #expect(model.pendingSharedValueMatches.isEmpty)
            #expect(model.statusMessage == "Nothing protected in app.")
            model.cancelSharedValueMatches()
            #expect(try VaultCore(vaultURL: vault).listScopes().isEmpty)

            model.setLineChoice(.useShared(id: "openai-api-key"), forKey: "OPENAI_API_KEY")
            await model.protectRecommended()
            #expect(model.pendingSharedValueMatches.isEmpty)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            #expect(try core.inspect("app").map(\.kind) == [.link(sharedID: "openai-api-key")])
        }
    }

    @Test("Protect all commits the rest and asks once per project with matches, in turn")
    func protectAllAsksPerProject() async throws {
        try await GateFixesTestSupport.withCandidates(
            [
                "alpha": "A_KEY=sk-same\nB_KEY=sk-same\n",
                "beta": "C_TOKEN=sk-same\n",
                "gamma": "D_KEY=sk-own\n",
            ],
            shared: ["shared-one": "sk-same"]
        ) { model, vault, _, fixture in
            await model.protectAllCandidates()

            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            #expect(try core.listScopes().map(\.identity) == ["gamma"])
            #expect(model.statusMessage == "Protected 1 project: 1 secret.")
            #expect(model.pendingSharedValueMatches.map(\.plan.name) == ["alpha", "beta"])
            let first = try #require(model.presentedSharedValueMatches)
            #expect(
                WorkshopModel.sharedValueMatchesMessage(for: first)
                    == "In alpha:\nA_KEY has the same value as the shared secret shared-one\n"
                    + "B_KEY has the same value as the shared secret shared-one")

            let alpha = try #require(model.takeSharedValueMatches())
            await model.answerSharedValueMatches(alpha, useShared: true)
            #expect(try core.inspect("alpha").map(\.kind) == Array(repeating: .link(sharedID: "shared-one"), count: 2))
            #expect(model.presentedSharedValueMatches?.plan.name == "beta")

            let beta = try #require(model.takeSharedValueMatches())
            await model.answerSharedValueMatches(beta, useShared: false)
            #expect(try core.getValue("C_TOKEN", inScope: "beta") == "sk-same")
            #expect(model.candidates.isEmpty)
            #expect(model.statusMessage == "Protected 1 project: 1 secret.")
        }
    }

    @Test("the match compares only lines protected for this project, first shared ID by name")
    func sharedValueMatchesPure() {
        let detected = [
            DetectedKey(
                key: "A", value: "v1", sourceFile: URL(fileURLWithPath: "/tmp/.env"), nameMatchedSharedID: nil),
            DetectedKey(
                key: "B", value: "v1", sourceFile: URL(fileURLWithPath: "/tmp/.env"), nameMatchedSharedID: nil),
            DetectedKey(
                key: "C", value: "v2", sourceFile: URL(fileURLWithPath: "/tmp/.env"), nameMatchedSharedID: nil),
        ]
        let decisions: [KeyDecision] = [
            .importAsLocal(key: "A"), .linkToShared(key: "B", sharedID: "x"), .importAsLocal(key: "C"),
            .importAsLocal(key: "MISSING"),
        ]
        let values = ["zeta": "v1", "alpha": "v1"]
        #expect(
            ProjectProtector.sharedValueMatches(decisions, detected: detected, sharedValues: values)
                == [.init(key: "A", sharedID: "alpha")])
        #expect(ProjectProtector.sharedValueMatches(decisions, detected: detected, sharedValues: [:]).isEmpty)
        #expect(ProjectChecker.sharedID(matching: "v2", in: values) == nil)

        let plan = WorkshopModel.ProtectPlan(
            directory: URL(fileURLWithPath: "/tmp/app"), scopeID: "app", name: "app", decisions: decisions)
        let held = WorkshopModel.SharedValueMatches(
            plan: plan, matches: [.init(key: "A", sharedID: "alpha")], origin: .page)
        #expect(
            held.planUsingShared.decisions == [
                .linkToShared(key: "A", sharedID: "alpha"), .linkToShared(key: "B", sharedID: "x"),
                .importAsLocal(key: "C"), .importAsLocal(key: "MISSING"),
            ])
    }
}
