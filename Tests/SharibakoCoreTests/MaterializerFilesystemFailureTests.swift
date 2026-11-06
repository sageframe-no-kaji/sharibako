import Foundation
import Testing

@testable import SharibakoCore

/// Filesystem failure-arm tests for `Materializer`.
///
/// Every `catch` that turns a POSIX refusal into
/// `VaultError.fileSystemError`.
///
/// Same provocation as `VaultCoreFilesystemFailureTests`: drop the read or
/// write bit inside an ephemeral temp tree, which is what an `.env` owned by
/// another user, a project directory mounted read-only, or a marker written by
/// root looks like from here. Modes are restored before teardown.
@Suite("Materializer filesystem failures")
struct MaterializerFilesystemFailureTests {
    /// Runs `body` with `url` set to `mode`, restoring `restore` afterwards.
    private func withMode(
        _ mode: Int, at url: URL, restoring restore: Int = 0o755, _ body: () throws -> Void
    ) throws {
        let fileManager = FileManager.default
        try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        defer {
            try? fileManager.setAttributes([.posixPermissions: restore], ofItemAtPath: url.path)
        }
        try body()
    }

    /// Asserts `error` is a `fileSystemError` whose path ends in `name`.
    private func expectFileSystemError(_ error: VaultError?, named name: String) {
        guard case .fileSystemError(let path, _) = error else {
            Issue.record("expected fileSystemError, got \(String(describing: error))")
            return
        }
        #expect(path.lastPathComponent == name)
    }

    /// A `Materializer` over an empty vault plus a project directory.
    private func withProject(
        _ body: (_ materializer: Materializer, _ project: URL, _ markerURL: URL) throws -> Void
    ) throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            try VaultTestSupport.writePlaceholderAge("API_KEY", inScope: "kanyo-dev", in: vault)
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let core = try VaultCore(vaultURL: vault)
                let materializer = Materializer(vaultCore: core, vaultURL: vault)
                try body(materializer, project, project.appendingPathComponent(".sharibako"))
            }
        }
    }

    // MARK: - Marker read/write

    @Test("loadMarker reports a filesystem error when the marker is unreadable")
    func loadMarkerUnreadable() throws {
        try withProject { materializer, _, markerURL in
            try "scope: kanyo-dev\nmaterialize_to: ./.env\n".write(
                to: markerURL, atomically: true, encoding: .utf8)

            try withMode(0o000, at: markerURL, restoring: 0o644) {
                let error = #expect(throws: VaultError.self) {
                    try materializer.loadMarker(at: markerURL)
                }
                expectFileSystemError(error, named: ".sharibako")
            }
        }
    }

    @Test("writeMarker reports a filesystem error when the directory is read-only")
    func writeMarkerIntoReadOnlyDirectory() throws {
        try withProject { materializer, project, markerURL in
            let marker = ScopeMarker(
                scope: "kanyo-dev", materializeTo: "./.env", markerURL: markerURL)

            try withMode(0o500, at: project) {
                let error = #expect(throws: VaultError.self) {
                    try materializer.writeMarker(marker, at: markerURL)
                }
                expectFileSystemError(error, named: ".sharibako")
            }
        }
    }

    // MARK: - clean

    @Test("clean reports a filesystem error when the target is unreadable")
    func cleanUnreadableTarget() throws {
        try withProject { materializer, project, markerURL in
            let targetURL = project.appendingPathComponent(".env")
            try "API_KEY=whatever\n".write(to: targetURL, atomically: true, encoding: .utf8)
            let marker = ScopeMarker(
                scope: "kanyo-dev", materializeTo: "./.env", markerURL: markerURL)

            try withMode(0o000, at: targetURL, restoring: 0o644) {
                let error = #expect(throws: VaultError.self) {
                    try materializer.clean(marker: marker)
                }
                expectFileSystemError(error, named: ".env")
            }
        }
    }

    @Test("clean reports a filesystem error when the file cannot be removed")
    func cleanUnremovableTarget() throws {
        try withProject { materializer, project, markerURL in
            let targetURL = project.appendingPathComponent(".env")
            // Only owned keys, so clean's answer is "delete the file" — which
            // the read-only parent directory then refuses.
            try "API_KEY=whatever\n".write(to: targetURL, atomically: true, encoding: .utf8)
            let marker = ScopeMarker(
                scope: "kanyo-dev", materializeTo: "./.env", markerURL: markerURL)

            try withMode(0o500, at: project) {
                let error = #expect(throws: VaultError.self) {
                    try materializer.clean(marker: marker)
                }
                expectFileSystemError(error, named: ".env")
            }
        }
    }

    // MARK: - heal

    @Test("heal reports a filesystem error when the target is unreadable")
    func healUnreadableTarget() throws {
        try withProject { materializer, project, markerURL in
            let targetURL = project.appendingPathComponent(".env")
            try "API_KEY=whatever\n".write(to: targetURL, atomically: true, encoding: .utf8)
            let marker = ScopeMarker(
                scope: "kanyo-dev", materializeTo: "./.env", markerURL: markerURL)

            try withMode(0o000, at: targetURL, restoring: 0o644) {
                let error = #expect(throws: VaultError.self) {
                    try materializer.heal(marker: marker)
                }
                expectFileSystemError(error, named: ".env")
            }
        }
    }

    // MARK: - resolveMarker

    @Test("resolveMarker falls back to the working directory when there are no scan roots")
    func resolveMarkerWithoutScanRoots() throws {
        try withProject { materializer, _, _ in
            // No roots to name in the error, so the hint falls back to the
            // process working directory rather than being absent.
            let error = #expect(throws: VaultError.self) {
                try materializer.resolveMarker(forScope: "kanyo-dev", scanRoots: [])
            }
            guard case .markerNotFound(let hint) = error else {
                Issue.record("expected markerNotFound, got \(String(describing: error))")
                return
            }
            #expect(hint.path == FileManager.default.currentDirectoryPath)
        }
    }
}
