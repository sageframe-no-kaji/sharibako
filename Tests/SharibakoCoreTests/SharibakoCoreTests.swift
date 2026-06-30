import Testing
@testable import SharibakoCore

@Suite("Smoke")
struct SmokeTests {
    @Test("SharibakoCore exposes a version string")
    func versionIsSet() {
        #expect(!SharibakoCore.version.isEmpty)
    }

    @Test("Truth is truth")
    func truth() {
        #expect(true)
    }
}
