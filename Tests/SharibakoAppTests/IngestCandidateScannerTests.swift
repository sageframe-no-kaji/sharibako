import Foundation
import Testing

@testable import Sharibako

/// Tests for `IngestCandidateScanner.findCandidates` (`WorkshopModel+Ingest.swift`)
/// — the bounded-depth `.env` walk behind the first-run wizard's finish-page
/// invite (ho-06.3 AT-02, Required Change 5).
///
/// Pure filesystem logic, no vault involved.
@Suite("IngestCandidateScanner")
struct IngestCandidateScannerTests {
    @Test("finds a directory with a .env file at the root itself")
    func findsRootCandidate() throws {
        try WorkshopTestSupport.withTempDirectory { root in
            try "KEY=value\n".write(
                to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

            let found = IngestCandidateScanner.findCandidates(under: root)

            #expect(found.count == 1)
            #expect(found.first?.standardizedFileURL.path == root.standardizedFileURL.path)
        }
    }

    @Test("finds .env-bearing directories one and two levels below root")
    func findsNestedCandidates() throws {
        try WorkshopTestSupport.withTempDirectory { root in
            let depth1 = root.appendingPathComponent("project-a")
            let depth2 = root.appendingPathComponent("group").appendingPathComponent("project-b")
            try FileManager.default.createDirectory(at: depth1, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: depth2, withIntermediateDirectories: true)
            try "A=1\n".write(
                to: depth1.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
            try "B=1\n".write(
                to: depth2.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

            let found = IngestCandidateScanner.findCandidates(under: root)

            #expect(found.map(\.lastPathComponent).sorted() == ["project-a", "project-b"])
        }
    }

    @Test("finds a nested project within the bounded depth")
    func findsNestedProject() throws {
        try WorkshopTestSupport.withTempDirectory { root in
            // The gate's real shape: <root>/<org>/<area>/<project> (depth 3).
            let nested = root.appendingPathComponent("edelmore")
                .appendingPathComponent("apps")
                .appendingPathComponent("diary")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try "NESTED=1\n".write(
                to: nested.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

            let found = IngestCandidateScanner.findCandidates(under: root)

            #expect(found.map(\.lastPathComponent) == ["diary"])
        }
    }

    @Test("does not descend past the bounded depth")
    func boundsDepth() throws {
        try WorkshopTestSupport.withTempDirectory { root in
            var deep = root
            for component in ["a", "b", "c", "d", "e", "f"] {
                deep = deep.appendingPathComponent(component)
            }
            try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
            try "TOO_DEEP=1\n".write(
                to: deep.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

            let found = IngestCandidateScanner.findCandidates(under: root)

            #expect(found.isEmpty)
        }
    }

    @Test("does not descend into dependency forests like node_modules")
    func skipsDependencyForests() throws {
        try WorkshopTestSupport.withTempDirectory { root in
            let buried = root.appendingPathComponent("web-app")
                .appendingPathComponent("node_modules")
                .appendingPathComponent("some-package")
            try FileManager.default.createDirectory(at: buried, withIntermediateDirectories: true)
            try "PACKAGE_ENV=1\n".write(
                to: buried.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

            let found = IngestCandidateScanner.findCandidates(under: root)

            #expect(found.isEmpty)
        }
    }

    @Test("a .env.local alone qualifies a directory")
    func envLocalQualifies() throws {
        try WorkshopTestSupport.withTempDirectory { root in
            let project = root.appendingPathComponent("local-only")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try "LOCAL=1\n".write(
                to: project.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8)

            let found = IngestCandidateScanner.findCandidates(under: root)

            #expect(found.map(\.lastPathComponent) == ["local-only"])
        }
    }

    @Test("skips hidden directories while walking")
    func skipsHiddenDirectories() throws {
        try WorkshopTestSupport.withTempDirectory { root in
            let hidden = root.appendingPathComponent(".git").appendingPathComponent("hooks")
            try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
            try "SHOULD_NOT_BE_FOUND=1\n".write(
                to: hidden.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

            let found = IngestCandidateScanner.findCandidates(under: root)

            #expect(found.isEmpty)
        }
    }

    @Test("returns an empty array for a directory with no .env-bearing subdirectories")
    func emptyWhenNothingFound() throws {
        try WorkshopTestSupport.withTempDirectory { root in
            let plain = root.appendingPathComponent("no-secrets-here")
            try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

            let found = IngestCandidateScanner.findCandidates(under: root)

            #expect(found.isEmpty)
        }
    }

    @Test("results are sorted by path")
    func resultsAreSorted() throws {
        try WorkshopTestSupport.withTempDirectory { root in
            for name in ["zebra", "alpha", "mid"] {
                let dir = root.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try "K=1\n".write(
                    to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
            }

            let found = IngestCandidateScanner.findCandidates(under: root)

            #expect(found.map(\.lastPathComponent) == ["alpha", "mid", "zebra"])
        }
    }
}
