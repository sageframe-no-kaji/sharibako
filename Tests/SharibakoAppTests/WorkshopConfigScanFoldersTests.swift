import Foundation
import Testing

@testable import Sharibako

/// Tests for the scan-folder writes in `WorkshopConfig` (ho-06.10 AT-04).
///
/// The whole list replaced, one folder removed, duplicates never written.
@Suite("WorkshopConfig scan folders")
struct WorkshopConfigScanFoldersTests {
    @Test("persistScanRoots writes the list in order, once each, and an empty list reads as none")
    func persistScanRoots() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            let config = WorkshopConfig.defaultConfigURL(home: home)
            let first = URL(fileURLWithPath: "/tmp/one")
            let second = URL(fileURLWithPath: "/tmp/two")
            try WorkshopConfig.persistScanRoots([second, first, second], configURL: config)
            #expect(WorkshopConfig.loadScanRoots(configURL: config).map(\.path) == ["/tmp/two", "/tmp/one"])
            try WorkshopConfig.persistScanRoot(first, configURL: config)
            #expect(WorkshopConfig.loadScanRoots(configURL: config).count == 2)
            try WorkshopConfig.persistScanRoots([], configURL: config)
            #expect(WorkshopConfig.loadScanRoots(configURL: config).isEmpty)
        }
    }

    @Test("removeScanRoot drops one folder by its standardized path and leaves the file alone otherwise")
    func removeScanRoot() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            let config = WorkshopConfig.defaultConfigURL(home: home)
            try WorkshopConfig.persistScanRoots(
                [URL(fileURLWithPath: "/tmp/one"), URL(fileURLWithPath: "/tmp/two")], configURL: config)
            try WorkshopConfig.removeScanRoot(URL(fileURLWithPath: "/tmp/x/../one"), configURL: config)
            #expect(WorkshopConfig.loadScanRoots(configURL: config).map(\.path) == ["/tmp/two"])

            let before = try String(contentsOf: config, encoding: .utf8)
            try WorkshopConfig.removeScanRoot(URL(fileURLWithPath: "/tmp/absent"), configURL: config)
            #expect(try String(contentsOf: config, encoding: .utf8) == before)
        }
    }
}
