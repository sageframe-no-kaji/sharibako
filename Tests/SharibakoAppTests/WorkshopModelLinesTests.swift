import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// Fixtures shared by the two lines suites.
enum LinesTestSupport {
    /// Writes a bare vault key file.
    ///
    /// `inspect` only reads its name, so no age key is needed. A `link`
    /// writes `<KEY>.link` naming that shared ID.
    static func writeVaultKey(_ key: String, scope: String, in vault: URL, link: String? = nil) throws {
        let name = link == nil ? "\(key).age" : "\(key).link"
        try (link ?? "ciphertext").write(
            to: vault.appendingPathComponent("scopes/\(scope)/\(name)"), atomically: true, encoding: .utf8)
    }
}

/// ho-06.10 AT-02 tests for the project page's lines.
///
/// From `WorkshopModel+Lines.swift`: the types' words, the pure merge of vault
/// keys and `.env` lines, the classifier defaults and the session flips, the
/// header state's words, and the scope ID a folder protects under. The
/// keyless load for every kind of page, the choice setter, and the secret
/// shim are in `WorkshopModelLinesLoadTests.swift` (the split is SwiftLint's
/// `type_body_length` ceiling).
///
/// Keyless throughout: vault keys are written as bare `.age`/`.link` files
/// (``VaultCore/inspect(_:)`` reads names, never contents), so nothing here
/// needs `age`, a key, or the Keychain. The reconcile semantics the retired
/// `IngestScanPlannerTests` covered — a key the project already owns is not
/// offered again; a claim file naming a project the vault lacks offers
/// everything — live here as the protected status and the Problem-page load.
@MainActor
@Suite("WorkshopModel Lines")
struct WorkshopModelLinesTests {
    private static let folder = URL(fileURLWithPath: "/tmp/bento")

    private static func detected(_ key: String, _ value: String, shared: String? = nil) -> DetectedKey {
        DetectedKey(
            key: key,
            value: value,
            sourceFile: folder.appendingPathComponent(".env"),
            nameMatchedSharedID: shared
        )
    }

    private static func env(_ lines: [DetectedKey]) -> WorkshopModel.EnvRead {
        WorkshopModel.EnvRead(directory: folder, lines: lines, warnings: [])
    }

    // MARK: - Words

    @Test("each choice has its plain words, its engine decision, and whether it protects")
    func choiceWords() {
        let choices: [WorkshopModel.LineChoice] = [
            .protectLocal, .useShared(id: "anthropic"), .makeShared(id: "openai"), .leaveAsSetting,
        ]
        #expect(
            choices.map(\.label) == [
                "Protect for this project", "Use shared secret anthropic", "Make it a shared secret",
                "Leave in .env as a setting",
            ])
        #expect(
            choices.map { $0.decision(forKey: "K") } == [
                .importAsLocal(key: "K"), .linkToShared(key: "K", sharedID: "anthropic"),
                .moveToShared(key: "K", newSharedID: "openai"), .leaveAlone(key: "K"),
            ])
        #expect(choices.map(\.protects) == [true, true, true, false])
    }

    @Test("the header states say the count, Protected and its clause, or no lines, each with its mark")
    func headerWords() {
        let states: [WorkshopModel.ProjectHeaderState] = [
            .unprotected(count: 1), .unprotected(count: 3), .protected(upToDate: nil),
            .protected(upToDate: true), .protected(upToDate: false, differing: 1),
            .protected(upToDate: false, differing: 2), .empty,
        ]
        #expect(
            states.map(\.label) == [
                "1 secret not protected", "3 secrets not protected", "Protected", "Protected · up to date",
                "Protected · 1 line differs", "Protected · 2 lines differ", "No lines",
            ])
        #expect(states[0].symbolName == "xmark.octagon.fill")
        #expect(states[2].symbolName == "checkmark.circle.fill")
        #expect(states[6].symbolName == "circle.dashed")
    }

    @Test("only protected and missing-from-.env lines are in the vault")
    func statusInVault() {
        let statuses: [WorkshopModel.LineStatus] = [
            .protected(kind: .value), .missingFromEnv, .notProtected, .setting,
        ]
        #expect(statuses.map(\.isInVault) == [true, true, false, false])
    }

    // MARK: - Derivation (pure)

    @Test("the merge orders secrets in file order then vault order, settings last, each with its status")
    func deriveOrderAndStatus() {
        let lines = WorkshopModel.deriveLines(
            vault: [
                SecretInfo(key: "API_KEY", kind: .value),
                SecretInfo(key: "OLD_TOKEN", kind: .value),
                SecretInfo(key: "LINKED", kind: .link(sharedID: "anthropic")),
            ],
            env: Self.env([
                Self.detected("PORT", "3000"),
                Self.detected("API_KEY", "sk-live"),
                Self.detected("STRIPE_SECRET", "sk_live_abc"),
                Self.detected("LINKED", "x"),
                Self.detected("LOG_LEVEL", "debug"),
            ]),
            flips: [:])
        #expect(lines.map(\.key) == ["API_KEY", "STRIPE_SECRET", "LINKED", "OLD_TOKEN", "PORT", "LOG_LEVEL"])
        #expect(
            lines.map(\.status) == [
                .protected(kind: .value), .notProtected, .protected(kind: .link(sharedID: "anthropic")),
                .missingFromEnv, .setting, .setting,
            ])
        // A line in the vault carries no value, class, reason, or choice.
        #expect(lines[0].value == nil && lines[0].lineClass == nil && lines[0].choice == nil)
        #expect(lines[0].classLabel == nil)
        #expect(lines[1].value == "sk_live_abc")
        #expect(lines[1].reason == "key ends in SECRET")
        #expect(lines[1].classLabel == "secret — key ends in SECRET")
        #expect(lines[1].choice == .protectLocal)
        #expect(lines[3].value == nil)
        #expect(lines[4].classLabel?.hasPrefix("setting — ") == true)
        #expect(lines[4].choice == .leaveAsSetting)
    }

    @Test("with no folder every vault key is plainly protected, never missing")
    func deriveWithoutFolder() {
        let lines = WorkshopModel.deriveLines(
            vault: [SecretInfo(key: "A", kind: .value), SecretInfo(key: "A", kind: .link(sharedID: "x"))],
            env: nil,
            flips: [:]
        )
        #expect(lines.map(\.status) == [.protected(kind: .value)])
    }

    @Test("a name-matched key defaults to its shared secret; a flip overrides the default")
    func deriveDefaultsAndFlips() {
        let read = Self.env([
            Self.detected("ANTHROPIC_API_KEY", "sk-ant", shared: "ANTHROPIC_API_KEY"),
            Self.detected("TOKEN", "t-1"),
        ])
        let flips = [
            WorkshopModel.lineChoiceKey(folder: Self.folder, key: "TOKEN"): WorkshopModel.LineChoice.leaveAsSetting
        ]
        let lines = WorkshopModel.deriveLines(vault: [], env: read, flips: flips)
        #expect(lines[0].choice == .useShared(id: "ANTHROPIC_API_KEY"))
        #expect(lines[0].reason == "key matches a shared entry in the vault")
        // The flip changes the choice, not the status: the classifier still
        // says secret, and the value is still in plain text.
        #expect(lines[1].choice == .leaveAsSetting)
        #expect(lines[1].status == .notProtected)
        #expect(WorkshopModel.defaultChoice(for: Self.detected("PORT", "1")) == .leaveAsSetting)
    }

    // MARK: - Scope ID

    @Test("a folder's project ID is its name in the identifier grammar, suffixed on collision")
    func suggestedScopeIDs() {
        func suggest(_ name: String, _ existing: Set<String> = []) -> String {
            WorkshopModel.suggestedScopeID(for: URL(fileURLWithPath: "/tmp/\(name)"), existing: existing)
        }
        #expect(suggest("bento") == "bento")
        #expect(suggest("My App") == "my-app")
        #expect(suggest("Falcon  Watch!!") == "falcon-watch")
        #expect(suggest("über.tool") == "ber.tool")
        #expect(suggest(".hidden_dir") == "hidden_dir")
        #expect(suggest("___x") == "___x")
        #expect(suggest("!!!") == "project")
        #expect(suggest("bento", ["bento"]) == "bento-2")
        #expect(suggest("bento", ["bento", "bento-2", "bento-3"]) == "bento-4")
        #expect(suggest("!!!", ["project"]) == "project-2")
    }
}
