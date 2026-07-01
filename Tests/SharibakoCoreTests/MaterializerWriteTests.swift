import Foundation
import Testing

@testable import SharibakoCore

/// Structural tests for `Materializer` — markers, scan, status.
///
/// The merge-oriented write-path tests (materialize, clean, heal) live in
/// `MaterializerMergeTests.swift`; keeping them in separate files keeps each
/// file/type under the length linter's ceiling.
@Suite("Materializer Write")
struct MaterializerWriteTests {
    // MARK: - Marker helpers

    @Test("loadMarker throws markerNotFound when the file does not exist")
    func loadMarkerMissing() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            let core = try VaultCore(vaultURL: vault)
            let mat = Materializer(vaultCore: core, vaultURL: vault)
            let missing = FileManager.default.temporaryDirectory
                .appendingPathComponent("nonexistent-\(UUID().uuidString)/.sharibako")
            #expect(throws: VaultError.self) {
                _ = try mat.loadMarker(at: missing)
            }
        }
    }

    @Test("loadMarker on valid YAML returns marker with correct targetURL")
    func loadMarkerValidYAML() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                try "scope: kanyo-dev\nmaterialize_to: ./.env.local\n"
                    .write(to: markerURL, atomically: true, encoding: .utf8)
                let core = try VaultCore(vaultURL: vault)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let marker = try mat.loadMarker(at: markerURL)
                #expect(marker.scope == "kanyo-dev")
                #expect(marker.materializeTo == "./.env.local")
                #expect(marker.markerURL.standardizedFileURL == markerURL.standardizedFileURL)
                #expect(marker.targetURL.lastPathComponent == ".env.local")
            }
        }
    }

    @Test("loadMarker defaults materializeTo to ./.env when omitted")
    func loadMarkerDefaultTarget() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                try "scope: kanyo-dev\n".write(to: markerURL, atomically: true, encoding: .utf8)
                let core = try VaultCore(vaultURL: vault)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let marker = try mat.loadMarker(at: markerURL)
                #expect(marker.materializeTo == nil)
                #expect(marker.targetURL.lastPathComponent == ".env")
            }
        }
    }

    @Test("loadMarker throws markerMalformed for invalid YAML")
    func loadMarkerInvalidYAML() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                try ":::not: yaml:::".write(to: markerURL, atomically: true, encoding: .utf8)
                let core = try VaultCore(vaultURL: vault)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                #expect(throws: VaultError.self) {
                    _ = try mat.loadMarker(at: markerURL)
                }
            }
        }
    }

    @Test("loadMarker throws markerMalformed when scope field is empty")
    func loadMarkerEmptyScope() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                try "scope: \"\"\nmaterialize_to: ./.env\n"
                    .write(to: markerURL, atomically: true, encoding: .utf8)
                let core = try VaultCore(vaultURL: vault)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                #expect(throws: VaultError.self) {
                    _ = try mat.loadMarker(at: markerURL)
                }
            }
        }
    }

    @Test("loadMarker rejects materialize_to values starting with ~ (not portable)")
    func loadMarkerRejectsTilde() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                try "scope: kanyo-dev\nmaterialize_to: ~/.env\n"
                    .write(to: markerURL, atomically: true, encoding: .utf8)
                let core = try VaultCore(vaultURL: vault)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                #expect(throws: VaultError.self) {
                    _ = try mat.loadMarker(at: markerURL)
                }
            }
        }
    }

    @Test("writeMarker then loadMarker round-trips")
    func writeMarkerRoundTrip() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let core = try VaultCore(vaultURL: vault)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let marker = ScopeMarker(
                    scope: "kanyo-dev",
                    materializeTo: "./config/.env",
                    markerURL: markerURL
                )
                try mat.writeMarker(marker, at: markerURL)
                let loaded = try mat.loadMarker(at: markerURL)
                #expect(loaded.scope == "kanyo-dev")
                #expect(loaded.materializeTo == "./config/.env")
            }
        }
    }

    @Test("resolveMarker walks up from a subdirectory to find the marker")
    func resolveMarkerWalksUp() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                try "scope: kanyo-dev\n".write(to: markerURL, atomically: true, encoding: .utf8)
                let deep = project.appendingPathComponent("src/app/handlers")
                try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
                let core = try VaultCore(vaultURL: vault)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let found = try mat.resolveMarker(startingFrom: deep)
                #expect(found.scope == "kanyo-dev")
            }
        }
    }

    @Test("resolveMarker throws markerNotFound when nothing is found up to root")
    func resolveMarkerNotFound() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let core = try VaultCore(vaultURL: vault)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                #expect(throws: VaultError.self) {
                    _ = try mat.resolveMarker(startingFrom: project)
                }
            }
        }
    }

    // MARK: - Scan

    @Test("scan finds a single marker at the root")
    func scanSingleMarker() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                try "scope: kanyo-dev\n".write(to: markerURL, atomically: true, encoding: .utf8)
                let core = try VaultCore(vaultURL: vault)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let markers = try mat.scan(roots: [project])
                #expect(markers.count == 1)
                #expect(markers[0].scope == "kanyo-dev")
            }
        }
    }

    @Test("scan finds a marker nested inside the root")
    func scanNestedMarker() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let subdir = project.appendingPathComponent("apps/kanyo")
                try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
                let markerURL = subdir.appendingPathComponent(".sharibako")
                try "scope: kanyo-dev\n".write(to: markerURL, atomically: true, encoding: .utf8)
                let core = try VaultCore(vaultURL: vault)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let markers = try mat.scan(roots: [project])
                #expect(markers.count == 1)
                #expect(markers[0].scope == "kanyo-dev")
            }
        }
    }

    @Test("scan on a root with no markers returns empty")
    func scanEmpty() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let core = try VaultCore(vaultURL: vault)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let markers = try mat.scan(roots: [project])
                #expect(markers.isEmpty)
            }
        }
    }

    @Test("resolveMarker(forScope:scanRoots:) returns the matching marker")
    func resolveMarkerForScope() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                try "scope: kanyo-dev\n".write(to: markerURL, atomically: true, encoding: .utf8)
                let core = try VaultCore(vaultURL: vault)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let marker = try mat.resolveMarker(forScope: "kanyo-dev", scanRoots: [project])
                #expect(marker.scope == "kanyo-dev")
            }
        }
    }

    @Test("resolveMarker(forScope:scanRoots:) throws when no marker matches the scope ID")
    func resolveMarkerForScopeThrows() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let core = try VaultCore(vaultURL: vault)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                #expect(throws: VaultError.self) {
                    _ = try mat.resolveMarker(forScope: "ghost", scanRoots: [project])
                }
            }
        }
    }

    @Test("scan deduplicates when overlapping roots would find the same marker twice")
    func scanDedupes() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let subdir = project.appendingPathComponent("apps")
                try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
                let markerURL = subdir.appendingPathComponent(".sharibako")
                try "scope: kanyo-dev\n".write(to: markerURL, atomically: true, encoding: .utf8)
                let core = try VaultCore(vaultURL: vault)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let markers = try mat.scan(roots: [project, subdir])
                #expect(markers.count == 1)
            }
        }
    }

    // MARK: - Status

    @Test("status returns .liveHere when the vault and a matching marker both exist")
    func statusLiveHere() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                try "scope: kanyo-dev\n".write(to: markerURL, atomically: true, encoding: .utf8)
                let core = try VaultCore(vaultURL: vault)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let state = try mat.status(scopeID: "kanyo-dev", scanRoots: [project])
                // swiftlint:disable:next pattern_matching_keywords
                guard case .liveHere(let mURL, let tURL) = state else {
                    Issue.record("expected .liveHere, got \(state)")
                    return
                }
                #expect(mURL.standardizedFileURL == markerURL.standardizedFileURL)
                #expect(tURL.lastPathComponent == ".env")
            }
        }
    }

    @Test("status returns .liveElsewhere when the vault has the scope but no local marker")
    func statusLiveElsewhere() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let core = try VaultCore(vaultURL: vault)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let state = try mat.status(scopeID: "kanyo-dev", scanRoots: [project])
                #expect(state == .liveElsewhere)
            }
        }
    }

    @Test("status returns .orphaned when a marker exists but the vault has no such scope")
    func statusOrphaned() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                try "scope: ghost\n".write(to: markerURL, atomically: true, encoding: .utf8)
                let core = try VaultCore(vaultURL: vault)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let state = try mat.status(scopeID: "ghost", scanRoots: [project])
                guard case .orphaned(let mURL, _) = state else {
                    Issue.record("expected .orphaned, got \(state)")
                    return
                }
                #expect(mURL.standardizedFileURL == markerURL.standardizedFileURL)
            }
        }
    }
}
