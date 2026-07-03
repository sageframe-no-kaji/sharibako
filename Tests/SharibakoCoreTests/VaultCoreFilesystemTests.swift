import Foundation
import Testing

@testable import SharibakoCore

/// Filesystem-level tests for `VaultCore`.
///
/// Covers the AT-01 operations that don't require `age` decryption. Each test
/// builds an ephemeral vault in a fresh temp directory and tears it down on exit.
@Suite("VaultCore Filesystem")
struct VaultCoreFilesystemTests {
    // MARK: - Initializer

    @Test("init succeeds for an existing vault directory")
    func initSucceedsForExistingDirectory() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            let core = try VaultCore(vaultURL: vault)
            #expect(core.vaultURL == vault)
        }
    }

    @Test("init throws vaultNotFound for a nonexistent path")
    func initThrowsForMissingDirectory() {
        let bogus = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: VaultError.self) {
            _ = try VaultCore(vaultURL: bogus)
        }
    }

    // MARK: - listScopes

    @Test("listScopes returns empty array for a vault with no scopes")
    func listScopesEmpty() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            let core = try VaultCore(vaultURL: vault)
            #expect(try core.listScopes().isEmpty)
        }
    }

    @Test("listScopes returns three scopes sorted by identity")
    func listScopesSorted() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeScope("kilo", type: .machine, in: vault)
            try VaultTestSupport.writeScope("alpha", type: .projectDev, in: vault)
            try VaultTestSupport.writeScope("mike", type: .service, displayName: "Mike Service", in: vault)

            let core = try VaultCore(vaultURL: vault)
            let scopes = try core.listScopes()
            #expect(scopes.map(\.identity) == ["alpha", "kilo", "mike"])
            #expect(scopes[0].type == .projectDev)
            #expect(scopes[2].displayName == "Mike Service")
        }
    }

    @Test("listScopes throws yamlDecodeError for a malformed scope.yaml")
    func listScopesRejectsMalformedYAML() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            let scopeDir = try VaultLayout.scopeDirectoryURL("busted", in: vault)
            try FileManager.default.createDirectory(at: scopeDir, withIntermediateDirectories: true)
            try "type: :::not valid yaml".write(
                to: try VaultLayout.scopeYAMLURL("busted", in: vault),
                atomically: true,
                encoding: .utf8
            )
            let core = try VaultCore(vaultURL: vault)
            #expect(throws: VaultError.self) {
                _ = try core.listScopes()
            }
        }
    }

    // MARK: - listShared

    @Test("listShared returns empty for a vault with no shared entries")
    func listSharedEmpty() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            let core = try VaultCore(vaultURL: vault)
            #expect(try core.listShared().isEmpty)
        }
    }

    @Test("listShared returns both stems sorted alphabetically")
    func listSharedSorted() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeSharedPlaceholderAge("openai-personal", in: vault)
            try VaultTestSupport.writeSharedPlaceholderAge("cloudflare-dns-token", in: vault)
            let core = try VaultCore(vaultURL: vault)
            #expect(try core.listShared() == ["cloudflare-dns-token", "openai-personal"])
        }
    }

    // MARK: - getScope

    @Test("getScope returns decoded metadata")
    func getScopeReturnsDecoded() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, displayName: "Kanyo (dev)", in: vault)
            let core = try VaultCore(vaultURL: vault)
            let scope = try core.getScope("kanyo-dev")
            #expect(scope.identity == "kanyo-dev")
            #expect(scope.type == .projectDev)
            #expect(scope.displayName == "Kanyo (dev)")
        }
    }

    @Test("getScope throws scopeNotFound for an absent scope")
    func getScopeMissing() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            let core = try VaultCore(vaultURL: vault)
            #expect(throws: VaultError.self) {
                _ = try core.getScope("ghost")
            }
        }
    }

    // MARK: - inspect

    @Test("inspect on scope with only .age files returns all as .value")
    func inspectValueOnly() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            try VaultTestSupport.writePlaceholderAge("DATABASE_URL", inScope: "kanyo-dev", in: vault)
            try VaultTestSupport.writePlaceholderAge("DEBUG", inScope: "kanyo-dev", in: vault)
            let core = try VaultCore(vaultURL: vault)
            let infos = try core.inspect("kanyo-dev")
            #expect(infos.map(\.key) == ["DATABASE_URL", "DEBUG"])
            #expect(infos.allSatisfy { $0.kind == .value })
        }
    }

    @Test("inspect on scope with only .link files returns .link kinds with correct IDs")
    func inspectLinksOnly() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            try VaultTestSupport.writeLink(
                "OPENAI_API_KEY", inScope: "kanyo-dev", sharedID: "openai-personal", in: vault)
            try VaultTestSupport.writeLink("TAILSCALE", inScope: "kanyo-dev", sharedID: "tailscale-auth-key", in: vault)
            let core = try VaultCore(vaultURL: vault)
            let infos = try core.inspect("kanyo-dev")
            #expect(infos.count == 2)
            #expect(infos[0] == SecretInfo(key: "OPENAI_API_KEY", kind: .link(sharedID: "openai-personal")))
            #expect(infos[1] == SecretInfo(key: "TAILSCALE", kind: .link(sharedID: "tailscale-auth-key")))
        }
    }

    @Test("inspect on mixed scope returns both kinds correctly")
    func inspectMixed() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            try VaultTestSupport.writePlaceholderAge("DATABASE_URL", inScope: "kanyo-dev", in: vault)
            try VaultTestSupport.writeLink(
                "OPENAI_API_KEY", inScope: "kanyo-dev", sharedID: "openai-personal", in: vault)
            let core = try VaultCore(vaultURL: vault)
            let infos = try core.inspect("kanyo-dev")
            #expect(infos.count == 2)
            #expect(infos[0].kind == .value)
            #expect(infos[0].key == "DATABASE_URL")
            #expect(infos[1].kind == .link(sharedID: "openai-personal"))
        }
    }

    @Test("inspect excludes scope.yaml")
    func inspectExcludesYAML() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            try VaultTestSupport.writePlaceholderAge("A", inScope: "kanyo-dev", in: vault)
            let core = try VaultCore(vaultURL: vault)
            let infos = try core.inspect("kanyo-dev")
            #expect(infos.map(\.key) == ["A"])
        }
    }

    @Test("inspect throws scopeNotFound for absent scope")
    func inspectMissingScope() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            let core = try VaultCore(vaultURL: vault)
            #expect(throws: VaultError.self) {
                _ = try core.inspect("ghost")
            }
        }
    }

    // MARK: - link

    @Test("link creates the .link file with correct content")
    func linkWritesFile() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault)
            try core.link("OPENAI_API_KEY", inScope: "kanyo-dev", toShared: "openai-personal")

            let linkURL = try VaultLayout.linkURL("OPENAI_API_KEY", inScope: "kanyo-dev", in: vault)
            let contents = try String(contentsOf: linkURL, encoding: .utf8)
            #expect(contents == "openai-personal")
        }
    }

    @Test("link deletes a pre-existing .age file for the same key")
    func linkReplacesAge() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            try VaultTestSupport.writePlaceholderAge("OPENAI_API_KEY", inScope: "kanyo-dev", in: vault)
            let ageURL = try VaultLayout.secretURL("OPENAI_API_KEY", inScope: "kanyo-dev", in: vault)
            #expect(FileManager.default.fileExists(atPath: ageURL.path))

            let core = try VaultCore(vaultURL: vault)
            try core.link("OPENAI_API_KEY", inScope: "kanyo-dev", toShared: "openai-personal")

            #expect(!FileManager.default.fileExists(atPath: ageURL.path))
            let infos = try core.inspect("kanyo-dev")
            #expect(infos == [SecretInfo(key: "OPENAI_API_KEY", kind: .link(sharedID: "openai-personal"))])
        }
    }

    @Test("link throws scopeNotFound for an absent scope")
    func linkMissingScope() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            let core = try VaultCore(vaultURL: vault)
            #expect(throws: VaultError.self) {
                try core.link("K", inScope: "ghost", toShared: "openai-personal")
            }
        }
    }

    // MARK: - linkGraph

    @Test("linkGraph builds mapping across multiple scopes and shared entries")
    func linkGraphMapping() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            try VaultTestSupport.writeScope("kanyo-prod", type: .projectProd, in: vault)
            try VaultTestSupport.writeScope("chumon-host", type: .machine, in: vault)

            try VaultTestSupport.writeLink(
                "OPENAI_API_KEY", inScope: "kanyo-dev", sharedID: "openai-personal", in: vault)
            try VaultTestSupport.writeLink(
                "OPENAI_API_KEY", inScope: "kanyo-prod", sharedID: "openai-personal", in: vault)
            try VaultTestSupport.writeLink(
                "TAILSCALE_AUTH_KEY",
                inScope: "chumon-host",
                sharedID: "tailscale-auth-key",
                in: vault
            )
            try VaultTestSupport.writePlaceholderAge("DEBUG", inScope: "kanyo-dev", in: vault)

            let core = try VaultCore(vaultURL: vault)
            let graph = try core.linkGraph()

            #expect(Set(graph.keys) == ["openai-personal", "tailscale-auth-key"])
            let openai = graph["openai-personal"] ?? []
            let openaiPairs = Set(openai.map { "\($0.scopeID)/\($0.key)" })
            #expect(openaiPairs == ["kanyo-dev/OPENAI_API_KEY", "kanyo-prod/OPENAI_API_KEY"])
            let tailscale = graph["tailscale-auth-key"] ?? []
            #expect(tailscale.count == 1)
            #expect(tailscale[0].scopeID == "chumon-host")
            #expect(tailscale[0].key == "TAILSCALE_AUTH_KEY")
        }
    }

    // MARK: - orphanedSharedEntries

    @Test("orphanedSharedEntries identifies unreferenced entries")
    func orphansIdentified() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeSharedPlaceholderAge("openai-personal", in: vault)
            try VaultTestSupport.writeSharedPlaceholderAge("abandoned-service", in: vault)

            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            try VaultTestSupport.writeLink(
                "OPENAI_API_KEY", inScope: "kanyo-dev", sharedID: "openai-personal", in: vault)

            let core = try VaultCore(vaultURL: vault)
            #expect(try core.orphanedSharedEntries() == ["abandoned-service"])
        }
    }

    @Test("orphanedSharedEntries returns empty when every shared entry is referenced")
    func orphansEmpty() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeSharedPlaceholderAge("openai-personal", in: vault)
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            try VaultTestSupport.writeLink(
                "OPENAI_API_KEY", inScope: "kanyo-dev", sharedID: "openai-personal", in: vault)
            let core = try VaultCore(vaultURL: vault)
            #expect(try core.orphanedSharedEntries().isEmpty)
        }
    }

    // MARK: - Boundary behavior

    @Test("ScopeMetadata memberwise init stores its arguments")
    func scopeMetadataMemberwiseInit() {
        let scope = ScopeMetadata(identity: "kanyo-dev", type: .projectDev, displayName: "Kanyo (dev)")
        #expect(scope.identity == "kanyo-dev")
        #expect(scope.type == .projectDev)
        #expect(scope.displayName == "Kanyo (dev)")

        let terse = ScopeMetadata(identity: "chumon-host", type: .machine)
        #expect(terse.displayName == nil)
    }

    @Test("Shell.findExecutable throws shellNotFound for an absent binary")
    func shellFindExecutableMissing() {
        #expect(throws: VaultError.self) {
            _ = try Shell.findExecutable("sharibako-nonexistent-binary-\(UUID().uuidString)")
        }
    }

    @Test("VaultCore init throws fileSystemError when the age key file is unreadable")
    func initFailsForUnreadableAgeKey() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            let missingKey = FileManager.default.temporaryDirectory
                .appendingPathComponent("sharibako-missing-\(UUID().uuidString).txt")
            #expect(throws: VaultError.self) {
                _ = try VaultCore(vaultURL: vault, ageKeyURL: missingKey)
            }
        }
    }

    @Test("listScopes on a vault missing its scopes/ directory returns empty")
    func listScopesNoScopesDir() throws {
        let bareVault = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: bareVault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bareVault) }
        let core = try VaultCore(vaultURL: bareVault)
        #expect(try core.listScopes().isEmpty)
    }

    @Test("listShared on a vault missing its shared/ directory returns empty")
    func listSharedNoSharedDir() throws {
        let bareVault = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: bareVault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bareVault) }
        let core = try VaultCore(vaultURL: bareVault)
        #expect(try core.listShared().isEmpty)
    }

    @Test("linkGraph on a vault missing its scopes/ directory returns an empty dictionary")
    func linkGraphNoScopesDir() throws {
        let bareVault = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: bareVault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bareVault) }
        let core = try VaultCore(vaultURL: bareVault)
        #expect(try core.linkGraph().isEmpty)
    }

    @Test("link throws fileSystemError when the scope directory is read-only")
    func linkFailsOnReadOnlyScopeDir() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let scopeDir = try VaultLayout.scopeDirectoryURL("kanyo-dev", in: vault)
            let fileManager = FileManager.default
            // Read + execute only; owner can't create new files inside.
            try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: scopeDir.path)
            defer {
                try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scopeDir.path)
            }
            let core = try VaultCore(vaultURL: vault)
            #expect(throws: VaultError.self) {
                try core.link("OPENAI_API_KEY", inScope: "kanyo-dev", toShared: "openai-personal")
            }
        }
    }
}
