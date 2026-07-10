import Foundation
import SharibakoCore
import Testing

@testable import Sharibako

/// Fixture helpers for Workshop tests: ephemeral temp directories, vault
/// layouts, and `scope.yaml` seeds — no Keychain, no signing, no real home.
private enum WorkshopTestSupport {
    /// Materializes an ephemeral empty temp directory and calls `body` with its URL.
    ///
    /// Removed on scope exit, even when `body` throws.
    static func withTempDirectory(_ body: (URL) throws -> Void) throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharibako-workshop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try body(tempDir)
    }

    /// Materializes a temp directory holding a vault layout (`scopes/` +
    /// `shared/`) and calls `body` with the vault URL.
    static func withTempVault(_ body: (URL) throws -> Void) throws {
        try withTempDirectory { tempDir in
            for sub in ["scopes", "shared"] {
                try FileManager.default.createDirectory(
                    at: tempDir.appendingPathComponent(sub),
                    withIntermediateDirectories: true
                )
            }
            try body(tempDir)
        }
    }

    /// Creates `scopes/<identity>/scope.yaml` in `vault`.
    static func writeScope(
        _ identity: String,
        type: ScopeType,
        displayName: String? = nil,
        in vault: URL
    ) throws {
        let scopeDir =
            vault
            .appendingPathComponent("scopes")
            .appendingPathComponent(identity)
        try FileManager.default.createDirectory(at: scopeDir, withIntermediateDirectories: true)
        var lines = [
            "identity: \(identity)",
            "type: \(type.rawValue)",
        ]
        if let displayName {
            lines.append("display_name: \(displayName)")
        }
        try (lines.joined(separator: "\n") + "\n").write(
            to: scopeDir.appendingPathComponent("scope.yaml"),
            atomically: true,
            encoding: .utf8
        )
    }
}

/// `WorkshopConfig` resolution tests: env → default precedence, vault
/// detection, and the scan-root config round-trip.
@Suite("WorkshopConfig")
struct WorkshopConfigTests {
    @Test("resolveVaultURL honours SHARIBAKO_VAULT")
    func vaultURLFromEnvironment() {
        let url = WorkshopConfig.resolveVaultURL(
            environment: ["SHARIBAKO_VAULT": "/tmp/custom-vault"],
            home: URL(fileURLWithPath: "/Users/nobody")
        )
        #expect(url.path == "/tmp/custom-vault")
    }

    @Test("resolveVaultURL falls back to ~/.sharibako/vault")
    func vaultURLDefault() {
        let url = WorkshopConfig.resolveVaultURL(
            environment: [:],
            home: URL(fileURLWithPath: "/Users/nobody")
        )
        #expect(url.path == "/Users/nobody/.sharibako/vault")
    }

    @Test("resolveDevAgeKeyURL honours SHARIBAKO_AGE_KEY")
    func devAgeKeyFromEnvironment() {
        let url = WorkshopConfig.resolveDevAgeKeyURL(
            environment: ["SHARIBAKO_AGE_KEY": "/tmp/key.txt"])
        #expect(url?.path == "/tmp/key.txt")
    }

    @Test("resolveDevAgeKeyURL is nil without the env var — the Keychain path")
    func devAgeKeyAbsent() {
        #expect(WorkshopConfig.resolveDevAgeKeyURL(environment: [:]) == nil)
    }

    @Test("isVaultDirectory accepts a scaffolded vault")
    func vaultDirectoryAccepted() throws {
        try WorkshopTestSupport.withTempVault { vault in
            #expect(WorkshopConfig.isVaultDirectory(vault))
        }
    }

    @Test("isVaultDirectory accepts a cloned vault carrying only one subdirectory")
    func vaultDirectoryPartialLayoutAccepted() throws {
        // git drops empty directories on clone (ho-04.12 D8): either
        // subdirectory alone must still read as a vault.
        try WorkshopTestSupport.withTempDirectory { tempDir in
            try FileManager.default.createDirectory(
                at: tempDir.appendingPathComponent("shared"),
                withIntermediateDirectories: true
            )
            #expect(WorkshopConfig.isVaultDirectory(tempDir))
        }
    }

    @Test("isVaultDirectory rejects an empty directory and a missing path")
    func vaultDirectoryRejected() throws {
        try WorkshopTestSupport.withTempDirectory { tempDir in
            #expect(!WorkshopConfig.isVaultDirectory(tempDir))
            let absent = tempDir.appendingPathComponent("nope")
            #expect(!WorkshopConfig.isVaultDirectory(absent))
        }
    }

    @Test("isVaultDirectory rejects a plain file")
    func vaultDirectoryRejectsFile() throws {
        try WorkshopTestSupport.withTempDirectory { tempDir in
            let file = tempDir.appendingPathComponent("vault")
            try "not a directory".write(to: file, atomically: true, encoding: .utf8)
            #expect(!WorkshopConfig.isVaultDirectory(file))
        }
    }

    @Test("defaultConfigURL lives under ~/Library/Application Support/Sharibako")
    func configURLShape() {
        let url = WorkshopConfig.defaultConfigURL(home: URL(fileURLWithPath: "/Users/nobody"))
        #expect(url.path == "/Users/nobody/Library/Application Support/Sharibako/config.yaml")
    }

    @Test("loadScanRoots returns [] for an absent config file")
    func scanRootsAbsent() throws {
        try WorkshopTestSupport.withTempDirectory { tempDir in
            let config = tempDir.appendingPathComponent("config.yaml")
            #expect(WorkshopConfig.loadScanRoots(configURL: config).isEmpty)
        }
    }

    @Test("loadScanRoots returns [] for malformed YAML — degrade, don't crash")
    func scanRootsMalformed() throws {
        try WorkshopTestSupport.withTempDirectory { tempDir in
            let config = tempDir.appendingPathComponent("config.yaml")
            try "scan_roots: :::not yaml".write(to: config, atomically: true, encoding: .utf8)
            #expect(WorkshopConfig.loadScanRoots(configURL: config).isEmpty)
        }
    }

    @Test("loadScanRoots returns [] when the key is missing")
    func scanRootsKeyMissing() throws {
        try WorkshopTestSupport.withTempDirectory { tempDir in
            let config = tempDir.appendingPathComponent("config.yaml")
            try "other_key: value\n".write(to: config, atomically: true, encoding: .utf8)
            #expect(WorkshopConfig.loadScanRoots(configURL: config).isEmpty)
        }
    }

    @Test("persistScanRoot round-trips through a fresh config file")
    func persistScanRootRoundTrip() throws {
        try WorkshopTestSupport.withTempDirectory { tempDir in
            // Nested path: persist must create the parent directory itself.
            let config =
                tempDir
                .appendingPathComponent("Sharibako")
                .appendingPathComponent("config.yaml")
            let root = tempDir.appendingPathComponent("Projects")

            try WorkshopConfig.persistScanRoot(root, configURL: config)

            let loaded = WorkshopConfig.loadScanRoots(configURL: config)
            #expect(loaded.map(\.path) == [root.path])
        }
    }

    @Test("persistScanRoot appends a second root and does not duplicate")
    func persistScanRootAppendsWithoutDuplicates() throws {
        try WorkshopTestSupport.withTempDirectory { tempDir in
            let config = tempDir.appendingPathComponent("config.yaml")
            let first = tempDir.appendingPathComponent("Projects")
            let second = tempDir.appendingPathComponent("Vaults")

            try WorkshopConfig.persistScanRoot(first, configURL: config)
            try WorkshopConfig.persistScanRoot(second, configURL: config)
            try WorkshopConfig.persistScanRoot(first, configURL: config)

            let loaded = WorkshopConfig.loadScanRoots(configURL: config)
            #expect(loaded.map(\.path) == [first.path, second.path])
        }
    }
}

/// `WorkshopModel` tests: vault-state resolution, scope loading and grouping,
/// error surfacing, and age-key provider selection.
@MainActor
@Suite("WorkshopModel")
struct WorkshopModelTests {
    @Test("A populated vault opens and loads scopes grouped by type")
    func opensPopulatedVault() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("kanyo", type: .service, in: vault)
            try WorkshopTestSupport.writeScope("m4bmaker", type: .projectDev, in: vault)
            try WorkshopTestSupport.writeScope(
                "glassroom", type: .projectDev, displayName: "Glassroom", in: vault)

            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )

            #expect(model.vaultState == .open(vaultURL: URL(fileURLWithPath: vault.path)))
            #expect(model.errorMessage == nil)
            #expect(model.scopes.map(\.identity) == ["glassroom", "kanyo", "m4bmaker"])

            let sections = model.scopeSections
            #expect(sections.map(\.type) == [.projectDev, .service])
            #expect(sections[0].scopes.map(\.identity) == ["glassroom", "m4bmaker"])
            #expect(sections[1].scopes.map(\.identity) == ["kanyo"])
        }
    }

    @Test("An absent path lands in .noVault naming the expected path")
    func absentPathIsNoVault() throws {
        try WorkshopTestSupport.withTempDirectory { tempDir in
            let absent = tempDir.appendingPathComponent("no-vault-here")
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": absent.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            #expect(model.vaultState == .noVault(expectedPath: URL(fileURLWithPath: absent.path)))
            #expect(model.scopes.isEmpty)
        }
    }

    @Test("An empty directory (no vault layout) lands in .noVault")
    func emptyDirectoryIsNoVault() throws {
        try WorkshopTestSupport.withTempDirectory { tempDir in
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": tempDir.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            #expect(model.vaultState == .noVault(expectedPath: URL(fileURLWithPath: tempDir.path)))
        }
    }

    @Test("Default resolution (no env) points at home's .sharibako/vault")
    func defaultResolutionUsesHome() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            let model = WorkshopModel(environment: [:], home: home)
            let expected =
                home
                .appendingPathComponent(".sharibako")
                .appendingPathComponent("vault")
            #expect(model.vaultState == .noVault(expectedPath: expected))
        }
    }

    @Test("A malformed scope.yaml surfaces as errorMessage, not a crash")
    func malformedScopeSurfacesError() throws {
        try WorkshopTestSupport.withTempVault { vault in
            let scopeDir =
                vault
                .appendingPathComponent("scopes")
                .appendingPathComponent("busted")
            try FileManager.default.createDirectory(
                at: scopeDir, withIntermediateDirectories: true)
            try "type: :::not valid yaml".write(
                to: scopeDir.appendingPathComponent("scope.yaml"),
                atomically: true,
                encoding: .utf8
            )

            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )

            #expect(model.errorMessage != nil)
            #expect(model.scopes.isEmpty)
        }
    }

    @Test("loadScopes clears a stale errorMessage on success")
    func reloadClearsError() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("alpha", type: .other, in: vault)
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.errorMessage = "stale"
            model.loadScopes()
            #expect(model.errorMessage == nil)
            #expect(model.scopes.count == 1)
        }
    }

    @Test("loadScopes is a no-op in the .noVault state")
    func loadScopesNoVaultIsNoOp() throws {
        try WorkshopTestSupport.withTempDirectory { tempDir in
            let absent = tempDir.appendingPathComponent("nope")
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": absent.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.loadScopes()
            #expect(model.scopes.isEmpty)
            #expect(model.errorMessage == nil)
        }
    }

    @Test("SHARIBAKO_AGE_KEY selects the file provider — the dev bypass")
    func devKeySelectsFileProvider() throws {
        try WorkshopTestSupport.withTempVault { vault in
            let model = WorkshopModel(
                environment: [
                    "SHARIBAKO_VAULT": vault.path,
                    "SHARIBAKO_AGE_KEY": "/tmp/dev-key.txt",
                ],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            #expect(model.devAgeKeyPath?.path == "/tmp/dev-key.txt")
            #expect(model.makeAgeKeyProvider() is GUIFileAgeKeyProvider)
        }
    }

    @Test("Without a dev key, the GUI's own Keychain adapter is selected")
    func keychainProviderByDefault() throws {
        try WorkshopTestSupport.withTempVault { vault in
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            #expect(model.devAgeKeyPath == nil)
            #expect(model.makeAgeKeyProvider() is GUIKeychainAgeKeyProvider)
        }
    }

    @Test("All five scope types render sections in the fixed order")
    func allSectionsInOrder() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("e-other", type: .other, in: vault)
            try WorkshopTestSupport.writeScope("d-machine", type: .machine, in: vault)
            try WorkshopTestSupport.writeScope("c-service", type: .service, in: vault)
            try WorkshopTestSupport.writeScope("b-prod", type: .projectProd, in: vault)
            try WorkshopTestSupport.writeScope("a-dev", type: .projectDev, in: vault)

            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )

            let sections = model.scopeSections
            #expect(sections.map(\.type) == WorkshopModel.sectionOrder)
            #expect(
                sections.map(\.title) == [
                    "Projects — dev", "Projects — prod", "Services", "Machines", "Other",
                ])
            #expect(sections.map(\.id) == sections.map(\.type.rawValue))
        }
    }

    @Test("message(for:) names the errors the model can hit")
    func errorMessages() {
        let path = URL(fileURLWithPath: "/tmp/somewhere")
        #expect(
            WorkshopModel.message(for: VaultError.vaultNotFound(path: path))
                == "No vault found at /tmp/somewhere.")
        #expect(
            WorkshopModel.message(
                for: VaultError.yamlDecodeError(path: path, underlying: CocoaError(.fileNoSuchFile))
            )
            .contains("not valid YAML"))
        #expect(
            WorkshopModel.message(
                for: VaultError.fileSystemError(path: path, underlying: CocoaError(.fileNoSuchFile))
            )
            .contains("/tmp/somewhere"))
        #expect(
            WorkshopModel.message(for: VaultError.scopeNotFound(id: "x"))
                .hasPrefix("Vault error:"))
        #expect(
            WorkshopModel.message(for: CocoaError(.fileNoSuchFile))
                .hasPrefix("Unexpected error:"))
    }
}
