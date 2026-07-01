import Foundation
import Testing

@testable import SharibakoCore

/// Tests for `Materializer.acceptIngest` — the four-way + skip decision matrix,
/// marker writes, and empty-scope creation.
@Suite("Materializer Accept Ingest")
struct MaterializerAcceptIngestTests {
    private struct DetectedSpec {
        let key: String
        let value: String
        let matchedShared: String?
    }

    private static func makeProposal(
        directory: URL,
        scopeID: String = "bento",
        detected: [DetectedSpec] = []
    ) -> ProposedScope {
        let keys = detected.map { spec in
            DetectedKey(
                key: spec.key,
                value: spec.value,
                sourceFile: directory.appendingPathComponent(".env"),
                nameMatchedSharedID: spec.matchedShared
            )
        }
        return ProposedScope(
            directory: directory,
            suggestedScopeID: scopeID,
            suggestedScopeType: .projectDev,
            detectedKeys: keys,
            suggestedKeysNeedingValues: [],
            parseWarnings: []
        )
    }

    // MARK: - Decision routing

    @Test("acceptIngest with .importAsLocal encrypts the detected value into scopes/<id>/<KEY>.age")
    func acceptImportAsLocal() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let proposal = Self.makeProposal(
                    directory: project,
                    detected: [DetectedSpec(key: "API_KEY", value: "sk-value", matchedShared: nil)]
                )
                try mat.acceptIngest(proposal, decisions: [.importAsLocal(key: "API_KEY")])
                #expect(try core.getValue("API_KEY", inScope: "bento") == "sk-value")
            }
        }
    }

    @Test("acceptIngest with .linkToShared writes a .link file pointing at the shared entry")
    func acceptLinkToShared() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeSharedEntry(
                "openai-personal",
                value: "sk-shared",
                vault: vault,
                fixture: fixture
            )
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let proposal = Self.makeProposal(
                    directory: project,
                    detected: [
                        DetectedSpec(key: "OPENAI_API_KEY", value: "sk-ignored", matchedShared: "openai-personal")
                    ]
                )
                try mat.acceptIngest(
                    proposal,
                    decisions: [.linkToShared(key: "OPENAI_API_KEY", sharedID: "openai-personal")]
                )
                #expect(try core.getValue("OPENAI_API_KEY", inScope: "bento") == "sk-shared")
            }
        }
    }

    @Test("acceptIngest with .moveToShared creates shared/<id>.age and links the scope key to it")
    func acceptMoveToShared() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let proposal = Self.makeProposal(
                    directory: project,
                    detected: [DetectedSpec(key: "OPENAI_API_KEY", value: "sk-live", matchedShared: nil)]
                )
                try mat.acceptIngest(
                    proposal,
                    decisions: [.moveToShared(key: "OPENAI_API_KEY", newSharedID: "openai-personal")]
                )
                #expect(try core.listShared() == ["openai-personal"])
                #expect(try core.getValue("OPENAI_API_KEY", inScope: "bento") == "sk-live")
            }
        }
    }

    @Test("acceptIngest with .leaveAlone writes nothing for that key")
    func acceptLeaveAlone() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let core = try VaultCore(vaultURL: vault)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let proposal = Self.makeProposal(
                    directory: project,
                    detected: [DetectedSpec(key: "DEBUG", value: "true", matchedShared: nil)]
                )
                try mat.acceptIngest(proposal, decisions: [.leaveAlone(key: "DEBUG")])
                let infos = try core.inspect("bento")
                #expect(infos.isEmpty)
            }
        }
    }

    @Test("acceptIngest with .skip writes nothing for that key")
    func acceptSkip() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let core = try VaultCore(vaultURL: vault)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let proposal = Self.makeProposal(
                    directory: project,
                    detected: [DetectedSpec(key: "MAYBE", value: "later", matchedShared: nil)]
                )
                try mat.acceptIngest(proposal, decisions: [.skip(key: "MAYBE")])
                let infos = try core.inspect("bento")
                #expect(infos.isEmpty)
            }
        }
    }

    // MARK: - Marker + scope creation

    @Test("acceptIngest writes .sharibako in the project directory with scope: <id>")
    func acceptWritesMarker() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let core = try VaultCore(vaultURL: vault)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let proposal = Self.makeProposal(directory: project)
                try mat.acceptIngest(proposal, decisions: [])
                let markerURL = project.appendingPathComponent(".sharibako")
                #expect(FileManager.default.fileExists(atPath: markerURL.path))
                let loaded = try mat.loadMarker(at: markerURL)
                #expect(loaded.scope == "bento")
            }
        }
    }

    @Test("acceptIngest with all .leaveAlone still creates an empty scope + scope.yaml")
    func acceptAllLeaveAloneStillCreatesScope() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let core = try VaultCore(vaultURL: vault)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let proposal = Self.makeProposal(
                    directory: project,
                    detected: [
                        DetectedSpec(key: "DEBUG", value: "true", matchedShared: nil),
                        DetectedSpec(key: "PORT", value: "3000", matchedShared: nil),
                    ]
                )
                try mat.acceptIngest(
                    proposal,
                    decisions: [.leaveAlone(key: "DEBUG"), .leaveAlone(key: "PORT")]
                )
                let scopes = try core.listScopes()
                #expect(scopes.map(\.identity) == ["bento"])
                #expect(scopes[0].type == .projectDev)
            }
        }
    }

    @Test("acceptIngest respects an explicit scopeType override")
    func acceptScopeTypeOverride() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let core = try VaultCore(vaultURL: vault)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let proposal = Self.makeProposal(directory: project)
                try mat.acceptIngest(proposal, decisions: [], scopeType: .projectProd)
                let scopes = try core.listScopes()
                #expect(scopes[0].type == .projectProd)
            }
        }
    }

    @Test("acceptIngest respects an explicit scopeID override")
    func acceptScopeIDOverride() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let core = try VaultCore(vaultURL: vault)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let proposal = Self.makeProposal(directory: project)
                try mat.acceptIngest(proposal, decisions: [], scopeID: "kanyo-dev")
                let scopes = try core.listScopes()
                #expect(scopes.map(\.identity) == ["kanyo-dev"])
                let markerURL = project.appendingPathComponent(".sharibako")
                let loaded = try mat.loadMarker(at: markerURL)
                #expect(loaded.scope == "kanyo-dev")
            }
        }
    }

    // MARK: - Mixed decisions and error paths

    @Test("acceptIngest routes mixed decisions independently within a single call")
    func acceptMixedDecisions() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeSharedEntry(
                "openai-personal",
                value: "sk-shared",
                vault: vault,
                fixture: fixture
            )
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let proposal = Self.makeProposal(
                    directory: project,
                    detected: [
                        DetectedSpec(
                            key: "OPENAI_API_KEY",
                            value: "sk-ignored",
                            matchedShared: "openai-personal"
                        ),
                        DetectedSpec(
                            key: "DATABASE_URL",
                            value: "postgres://x@y/z",
                            matchedShared: nil
                        ),
                        DetectedSpec(key: "DEBUG", value: "true", matchedShared: nil),
                    ]
                )
                try mat.acceptIngest(
                    proposal,
                    decisions: [
                        .linkToShared(key: "OPENAI_API_KEY", sharedID: "openai-personal"),
                        .importAsLocal(key: "DATABASE_URL"),
                        .leaveAlone(key: "DEBUG"),
                    ]
                )
                let infos = try core.inspect("bento").map(\.key)
                #expect(infos == ["DATABASE_URL", "OPENAI_API_KEY"])
                #expect(try core.getValue("DATABASE_URL", inScope: "bento") == "postgres://x@y/z")
                #expect(try core.getValue("OPENAI_API_KEY", inScope: "bento") == "sk-shared")
            }
        }
    }

    @Test("acceptIngest throws ingestKeyMismatch when a decision names a key not in the proposal")
    func acceptRejectsUnknownKey() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let core = try VaultCore(vaultURL: vault)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let proposal = Self.makeProposal(
                    directory: project,
                    detected: [DetectedSpec(key: "A", value: "1", matchedShared: nil)]
                )
                #expect(throws: VaultError.self) {
                    try mat.acceptIngest(proposal, decisions: [.importAsLocal(key: "NOT_DETECTED")])
                }
            }
        }
    }

    @Test("acceptIngest with .linkToShared to a nonexistent shared ID throws sharedEntryNotFound")
    func acceptRejectsNonexistentShared() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let core = try VaultCore(vaultURL: vault)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let proposal = Self.makeProposal(
                    directory: project,
                    detected: [DetectedSpec(key: "OPENAI_API_KEY", value: "sk-live", matchedShared: nil)]
                )
                #expect(throws: VaultError.self) {
                    try mat.acceptIngest(
                        proposal,
                        decisions: [.linkToShared(key: "OPENAI_API_KEY", sharedID: "ghost")]
                    )
                }
            }
        }
    }
}
