import Foundation
import Testing

@testable import SharibakoCore

/// Identifier-grammar and traversal-containment tests (ho-04.9).
///
/// Scope IDs, keys, shared-entry IDs, `.link` payloads, and marker fields
/// sync via git from other machines — these suites specify that none of them
/// can direct a vault operation outside the vault, and that `materialize_to`
/// cannot aim a write (or `clean`'s delete) outside the marker's directory.
@Suite("Identifier grammar")
struct IdentifierGrammarTests {
    @Test(
        "Conforming identifiers are accepted",
        arguments: [
            "kanyo-dev", "OPENAI_API_KEY", "a", "_leading-underscore", "9lives",
            "a.b-c_d", "openai-personal", "API_KEY_2",
        ]
    )
    func acceptsValidIdentifiers(_ value: String) {
        #expect(VaultLayout.isValidIdentifier(value))
        #expect(VaultCore.isValidIdentifier(value))
    }

    @Test(
        "Out-of-grammar identifiers are rejected",
        arguments: [
            "", ".", "..", "../x", "a/b", "/abs", ".hidden", "-dash-first",
            ".sharibako-tmp-abc", "a b", "café", "key\n", "a:b", "~home",
        ]
    )
    func rejectsInvalidIdentifiers(_ value: String) {
        #expect(!VaultLayout.isValidIdentifier(value))
    }
}

/// Traversal attempts through each identifier-shaped input class.
@Suite("Traversal containment — identifiers")
struct IdentifierTraversalTests {
    @Test("addSecret with a traversal scope ID throws before touching the filesystem")
    func addSecretRejectsTraversalScope() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            let error = #expect(throws: VaultError.self) {
                try core.addSecret("KEY", value: "v", inScope: "../../outside")
            }
            guard case .invalidIdentifier(let kind, let value, _) = error else {
                Issue.record("expected invalidIdentifier, got \(String(describing: error))")
                return
            }
            #expect(kind == .scope)
            #expect(value == "../../outside")
        }
    }

    @Test("addSecret with a traversal key throws and writes nothing outside the scope")
    func addSecretRejectsTraversalKey() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            #expect(throws: VaultError.self) {
                try core.addSecret("../../evil", value: "v", inScope: "kanyo-dev")
            }
            // Nothing landed beside (or above) the scopes directory.
            let escaped = vault.appendingPathComponent("evil.age")
            #expect(!FileManager.default.fileExists(atPath: escaped.path))
        }
    }

    @Test("createScope with a traversal ID throws and creates no directory")
    func createScopeRejectsTraversal() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            let core = try VaultCore(vaultURL: vault)
            #expect(throws: VaultError.self) {
                try core.createScope("../escapee", type: .projectDev)
            }
            let escaped = vault.appendingPathComponent("escapee")
            #expect(!FileManager.default.fileExists(atPath: escaped.path))
        }
    }

    @Test("link refuses to write a traversal payload (write side of the .link contract)")
    func linkRejectsTraversalSharedID() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault)
            #expect(throws: VaultError.self) {
                try core.link("KEY", inScope: "kanyo-dev", toShared: "../../../etc/target")
            }
        }
    }

    @Test("A tampered .link payload throws invalidIdentifier naming the link file")
    func tamperedLinkPayloadRejected() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            // Bypass link() and write the hostile payload directly, as a
            // git-synced tampered file would arrive.
            let linkURL = try VaultLayout.linkURL("KEY", inScope: "kanyo-dev", in: vault)
            try "../../../home/user/.ssh/id_rsa".write(to: linkURL, atomically: true, encoding: .utf8)

            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            let error = #expect(throws: VaultError.self) {
                _ = try core.getValue("KEY", inScope: "kanyo-dev")
            }
            guard case .invalidIdentifier(let kind, _, let source) = error else {
                Issue.record("expected invalidIdentifier, got \(String(describing: error))")
                return
            }
            #expect(kind == .sharedEntry)
            #expect(source?.lastPathComponent == "KEY.link")
        }
    }

    @Test("Listing verbs skip out-of-grammar names instead of throwing")
    func listingSkipsStrayNames() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            // A stray directory and a stray shared file, both out of grammar.
            let strayDir = VaultLayout.scopesDirectoryURL(in: vault)
                .appendingPathComponent("bad name", isDirectory: true)
            try FileManager.default.createDirectory(at: strayDir, withIntermediateDirectories: true)
            let strayShared = VaultLayout.sharedDirectoryURL(in: vault)
                .appendingPathComponent("odd name.age")
            try "x".write(to: strayShared, atomically: true, encoding: .utf8)

            let core = try VaultCore(vaultURL: vault)
            #expect(try core.listScopes().map(\.identity) == ["kanyo-dev"])
            #expect(try core.listShared().isEmpty)
        }
    }
}

/// `materialize_to` containment: relative-only, inside the marker's subtree.
@Suite("Traversal containment — marker targets")
struct MarkerTargetContainmentTests {
    private func marker(_ materializeTo: String?, in project: URL) -> ScopeMarker {
        ScopeMarker(
            scope: "kanyo-dev",
            materializeTo: materializeTo,
            markerURL: project.appendingPathComponent(".sharibako")
        )
    }

    @Test(
        "Contained relative targets validate",
        arguments: ["./.env", ".env.local", "config/.env", "./sub/dir/.env"]
    )
    func acceptsContainedTargets(_ target: String) throws {
        try VaultTestSupport.withEphemeralProjectDirectory { project in
            let url = try marker(target, in: project).validatedTargetURL()
            #expect(url.path.hasPrefix(project.standardizedFileURL.path))
        }
    }

    @Test(
        "Absolute, ~-prefixed, and escaping targets are rejected",
        arguments: ["/etc/cron.d/x", "~/x", "../outside.env", "sub/../../outside.env"]
    )
    func rejectsEscapingTargets(_ target: String) throws {
        try VaultTestSupport.withEphemeralProjectDirectory { project in
            #expect(throws: VaultError.self) {
                _ = try marker(target, in: project).validatedTargetURL()
            }
        }
    }

    @Test("loadMarker rejects a marker whose target escapes, at load time")
    func loadMarkerRejectsEscapingTarget() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                try "scope: kanyo-dev\nmaterialize_to: ../../victim.env\n"
                    .write(to: markerURL, atomically: true, encoding: .utf8)
                let core = try VaultCore(vaultURL: vault)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                #expect(throws: VaultError.self) {
                    _ = try mat.loadMarker(at: markerURL)
                }
            }
        }
    }

    @Test("loadMarker rejects a traversal scope field")
    func loadMarkerRejectsTraversalScope() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                try "scope: ../../../tmp/x\n".write(to: markerURL, atomically: true, encoding: .utf8)
                let core = try VaultCore(vaultURL: vault)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                #expect(throws: VaultError.self) {
                    _ = try mat.loadMarker(at: markerURL)
                }
            }
        }
    }

    @Test("clean with an escaping marker throws and the outside file survives")
    func cleanCannotDeleteOutsideTarget() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                // The victim sits OUTSIDE the marker's directory; before
                // ho-04.9, clean would resolve the target there and could
                // removeItem() it.
                let inner = project.appendingPathComponent("inner", isDirectory: true)
                try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
                let victim = project.appendingPathComponent("victim.env")
                try "PRECIOUS=1\n".write(to: victim, atomically: true, encoding: .utf8)

                let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let hostile = ScopeMarker(
                    scope: "kanyo-dev",
                    materializeTo: "../victim.env",
                    markerURL: inner.appendingPathComponent(".sharibako")
                )
                #expect(throws: VaultError.self) {
                    _ = try mat.clean(marker: hostile)
                }
                #expect(FileManager.default.fileExists(atPath: victim.path))
                #expect(try String(contentsOf: victim, encoding: .utf8) == "PRECIOUS=1\n")
            }
        }
    }

    @Test("materialize with an escaping marker throws and writes nothing outside")
    func materializeCannotWriteOutsideTarget() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("API_KEY", value: "sk-live", inScope: "kanyo-dev")
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let inner = project.appendingPathComponent("inner", isDirectory: true)
                try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let hostile = ScopeMarker(
                    scope: "kanyo-dev",
                    materializeTo: "../leaked.env",
                    markerURL: inner.appendingPathComponent(".sharibako")
                )
                #expect(throws: VaultError.self) {
                    _ = try mat.materialize(marker: hostile)
                }
                let leaked = project.appendingPathComponent("leaked.env")
                #expect(!FileManager.default.fileExists(atPath: leaked.path))
            }
        }
    }
}

/// Remote-URL transport allowlist (defense-in-depth; `setRemote` is not
/// reachable from git-synced vault data today).
@Suite("Remote URL allowlist")
struct RemoteURLAllowlistTests {
    @Test(
        "Allowed transports are accepted",
        arguments: [
            "https://github.com/org/repo.git",
            "ssh://git@host/repo.git",
            "git@github.com:org/repo.git",
        ]
    )
    func acceptsAllowedTransports(_ url: String) throws {
        try VaultTestSupport.withEphemeralGitVault { vault in
            let conduit = try Conduit(vaultURL: vault)
            try conduit.setRemote(url)
            #expect(try conduit.remoteURL() == url)
        }
    }

    @Test("Absolute local paths are accepted (test remotes, local mirrors)")
    func acceptsLocalPath() throws {
        try VaultTestSupport.withEphemeralGitVault { vault in
            let conduit = try Conduit(vaultURL: vault)
            try conduit.setRemote(vault.path)
            #expect(try conduit.remoteURL() == vault.path)
        }
    }

    @Test(
        "Transport helpers and unrecognized transports are rejected",
        arguments: [
            "ext::sh -c 'touch /tmp/pwned'",
            "fd::7",
            "git://host/repo.git",
            "http://host/repo.git",
            "relative/path",
            "",
        ]
    )
    func rejectsDisallowedTransports(_ url: String) throws {
        try VaultTestSupport.withEphemeralGitVault { vault in
            let conduit = try Conduit(vaultURL: vault)
            let error = #expect(throws: VaultError.self) {
                try conduit.setRemote(url)
            }
            guard case .remoteURLRejected = error else {
                Issue.record("expected remoteURLRejected, got \(String(describing: error))")
                return
            }
            // The rejected URL never reached git's config.
            #expect(try conduit.remoteURL() == nil)
        }
    }
}
