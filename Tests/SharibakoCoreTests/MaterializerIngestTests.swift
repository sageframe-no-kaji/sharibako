import Foundation
import Testing

@testable import SharibakoCore

/// Tests for `Materializer.ingest` — scope ID suggestion, `.env`-family merging,
/// shared-name matching.
///
/// `acceptIngest` execution lives in `MaterializerAcceptIngestTests`; splitting
/// the two struct bodies keeps each under the type-body-length ceiling.
@Suite("Materializer Ingest")
struct MaterializerIngestTests {
    // MARK: - Scope ID suggestion

    @Test("ingest on a fresh vault with directory 'bento' suggests 'bento'")
    func scopeIDFreshDirectory() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { root in
                let project = root.appendingPathComponent("bento")
                try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
                let mat = Materializer(vaultCore: try VaultCore(vaultURL: vault), vaultURL: vault)
                let proposal = try mat.ingest(directory: project)
                #expect(proposal.suggestedScopeID == "bento")
                #expect(proposal.suggestedScopeType == .projectDev)
            }
        }
    }

    @Test("ingest suggests '<name>-dev' when the vault already has that scope")
    func scopeIDFirstCollision() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeScope("bento", type: .projectDev, in: vault)
            try VaultTestSupport.withEphemeralProjectDirectory { root in
                let project = root.appendingPathComponent("bento")
                try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
                let mat = Materializer(vaultCore: try VaultCore(vaultURL: vault), vaultURL: vault)
                let proposal = try mat.ingest(directory: project)
                #expect(proposal.suggestedScopeID == "bento-dev")
            }
        }
    }

    @Test("ingest suggests '<name>-dev-2' when '<name>' and '<name>-dev' both exist")
    func scopeIDSecondCollision() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeScope("bento", type: .projectDev, in: vault)
            try VaultTestSupport.writeScope("bento-dev", type: .projectDev, in: vault)
            try VaultTestSupport.withEphemeralProjectDirectory { root in
                let project = root.appendingPathComponent("bento")
                try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
                let mat = Materializer(vaultCore: try VaultCore(vaultURL: vault), vaultURL: vault)
                let proposal = try mat.ingest(directory: project)
                #expect(proposal.suggestedScopeID == "bento-dev-2")
            }
        }
    }

    @Test("ingest sanitizes uppercase, spaces, and punctuation in directory names")
    func scopeIDSanitizesWeirdName() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { root in
                let project = root.appendingPathComponent("My Weird Name!")
                try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
                let mat = Materializer(vaultCore: try VaultCore(vaultURL: vault), vaultURL: vault)
                let proposal = try mat.ingest(directory: project)
                #expect(proposal.suggestedScopeID == "my-weird-name")
            }
        }
    }

    @Test("ingest falls back to 'scope' when sanitization produces an empty string")
    func scopeIDAllInvalidFallback() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { root in
                let project = root.appendingPathComponent("___")
                try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
                let mat = Materializer(vaultCore: try VaultCore(vaultURL: vault), vaultURL: vault)
                let proposal = try mat.ingest(directory: project)
                #expect(proposal.suggestedScopeID == "scope")
            }
        }
    }

    // MARK: - Detection and merging

    @Test("ingest with only .env returns detectedKeys in file order")
    func ingestOnlyEnv() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let envURL = project.appendingPathComponent(".env")
                try "A=1\nB=two\nC=three\n".write(to: envURL, atomically: true, encoding: .utf8)
                let mat = Materializer(vaultCore: try VaultCore(vaultURL: vault), vaultURL: vault)
                let proposal = try mat.ingest(directory: project)
                #expect(proposal.detectedKeys.map(\.key) == ["A", "B", "C"])
                #expect(proposal.detectedKeys.map(\.value) == ["1", "two", "three"])
                #expect(proposal.suggestedKeysNeedingValues.isEmpty)
            }
        }
    }

    @Test("ingest merges .env.local over .env for shared keys and appends new keys from .env.local")
    func ingestEnvLocalOverrides() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let envURL = project.appendingPathComponent(".env")
                try "A=1\nB=two\n".write(to: envURL, atomically: true, encoding: .utf8)
                let envLocalURL = project.appendingPathComponent(".env.local")
                try "B=override\nC=three\n".write(to: envLocalURL, atomically: true, encoding: .utf8)
                let mat = Materializer(vaultCore: try VaultCore(vaultURL: vault), vaultURL: vault)
                let proposal = try mat.ingest(directory: project)
                #expect(proposal.detectedKeys.map(\.key) == ["A", "B", "C"])
                let bEntry = proposal.detectedKeys.first { $0.key == "B" }
                #expect(bEntry?.value == "override")
                #expect(bEntry?.sourceFile.lastPathComponent == ".env.local")
                let cEntry = proposal.detectedKeys.first { $0.key == "C" }
                #expect(cEntry?.sourceFile.lastPathComponent == ".env.local")
            }
        }
    }

    @Test("ingest sends .env.example keys absent from .env/.env.local to suggestedKeysNeedingValues")
    func ingestEnvExampleChecklist() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let envURL = project.appendingPathComponent(".env")
                try "A=1\n".write(to: envURL, atomically: true, encoding: .utf8)
                let exURL = project.appendingPathComponent(".env.example")
                try "A=\nB=\nC=\n".write(to: exURL, atomically: true, encoding: .utf8)
                let mat = Materializer(vaultCore: try VaultCore(vaultURL: vault), vaultURL: vault)
                let proposal = try mat.ingest(directory: project)
                #expect(proposal.detectedKeys.map(\.key) == ["A"])
                #expect(proposal.suggestedKeysNeedingValues == ["B", "C"])
            }
        }
    }

    @Test("ingest with only .env.example returns no detectedKeys and all keys in suggestedKeysNeedingValues")
    func ingestOnlyEnvExample() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let exURL = project.appendingPathComponent(".env.example")
                try "A=\nB=\n".write(to: exURL, atomically: true, encoding: .utf8)
                let mat = Materializer(vaultCore: try VaultCore(vaultURL: vault), vaultURL: vault)
                let proposal = try mat.ingest(directory: project)
                #expect(proposal.detectedKeys.isEmpty)
                #expect(proposal.suggestedKeysNeedingValues == ["A", "B"])
            }
        }
    }

    @Test("ingest on a directory with no .env-family files returns an empty proposal")
    func ingestNoFiles() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let mat = Materializer(vaultCore: try VaultCore(vaultURL: vault), vaultURL: vault)
                let proposal = try mat.ingest(directory: project)
                #expect(proposal.detectedKeys.isEmpty)
                #expect(proposal.suggestedKeysNeedingValues.isEmpty)
                #expect(proposal.parseWarnings.isEmpty)
            }
        }
    }

    @Test("ingest collects parse warnings from malformed lines in any of the three files")
    func ingestCollectsWarnings() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let envURL = project.appendingPathComponent(".env")
                try "A=1\n1BAD=nope\n".write(to: envURL, atomically: true, encoding: .utf8)
                let mat = Materializer(vaultCore: try VaultCore(vaultURL: vault), vaultURL: vault)
                let proposal = try mat.ingest(directory: project)
                #expect(!proposal.parseWarnings.isEmpty)
                #expect(proposal.detectedKeys.map(\.key) == ["A"])
            }
        }
    }

    // MARK: - Shared name-matching

    @Test("ingest marks nameMatchedSharedID when a detected key exactly matches a shared ID")
    func ingestExactSharedMatch() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeSharedPlaceholderAge("OPENAI_API_KEY", in: vault)
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let envURL = project.appendingPathComponent(".env")
                try "OPENAI_API_KEY=sk-live\nDEBUG=true\n"
                    .write(to: envURL, atomically: true, encoding: .utf8)
                let mat = Materializer(vaultCore: try VaultCore(vaultURL: vault), vaultURL: vault)
                let proposal = try mat.ingest(directory: project)
                let openai = proposal.detectedKeys.first { $0.key == "OPENAI_API_KEY" }
                let debug = proposal.detectedKeys.first { $0.key == "DEBUG" }
                #expect(openai?.nameMatchedSharedID == "OPENAI_API_KEY")
                #expect(debug?.nameMatchedSharedID == nil)
            }
        }
    }

    @Test("ingest does NOT match shared IDs when case differs (case-sensitive)")
    func ingestSharedMatchIsCaseSensitive() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeSharedPlaceholderAge("openai_api_key", in: vault)
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let envURL = project.appendingPathComponent(".env")
                try "OPENAI_API_KEY=sk-live\n".write(to: envURL, atomically: true, encoding: .utf8)
                let mat = Materializer(vaultCore: try VaultCore(vaultURL: vault), vaultURL: vault)
                let proposal = try mat.ingest(directory: project)
                #expect(proposal.detectedKeys[0].nameMatchedSharedID == nil)
            }
        }
    }
}
