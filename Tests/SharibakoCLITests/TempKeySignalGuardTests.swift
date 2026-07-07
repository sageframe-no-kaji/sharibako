import Foundation
import Testing

@testable import SharibakoCLI

/// Thread-safe recorder for the guard's scrub count and the re-raised signal.
private final class GuardProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var scrubs = 0
    private var raised: [Int32] = []

    func recordScrub() {
        lock.lock()
        scrubs += 1
        lock.unlock()
    }

    func recordRaise(_ sig: Int32) {
        lock.lock()
        raised.append(sig)
        lock.unlock()
    }

    var scrubCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return scrubs
    }

    var raisedSignals: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return raised
    }
}

/// Tests for the temp-key signal guard (ho-04.12 D1).
///
/// The scrub action and the re-raise are both injected, so `handle(_:)` is
/// driven directly — no real signal is delivered to the test runner. The
/// default re-raise (restore SIG_DFL + `raise`) would kill the process, so
/// every test supplies a recording re-raise instead.
@Suite("TempKeySignalGuard")
struct TempKeySignalGuardTests {
    @Test("handle scrubs the guarded file and re-raises the signal")
    func handleScrubsAndReraises() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("guard-probe-\(UUID().uuidString)")
        try Data("SECRET".utf8).write(to: file)
        #expect(FileManager.default.fileExists(atPath: file.path))

        let probe = GuardProbe()
        let signalGuard = TempKeySignalGuard(
            scrub: {
                probe.recordScrub()
                try? FileManager.default.removeItem(at: file)
            },
            reraise: { probe.recordRaise($0) }
        )

        signalGuard.handle(SIGINT)

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(probe.raisedSignals == [SIGINT])
        #expect(probe.scrubCount == 1)
    }

    @Test("handle is idempotent — a racing second signal scrubs only once")
    func handleScrubsOnce() {
        let probe = GuardProbe()
        let signalGuard = TempKeySignalGuard(
            scrub: { probe.recordScrub() },
            reraise: { probe.recordRaise($0) }
        )

        signalGuard.handle(SIGTERM)
        signalGuard.handle(SIGHUP)

        #expect(probe.scrubCount == 1)
        #expect(probe.raisedSignals == [SIGTERM])
    }

    @Test("install then teardown runs cleanly and fires no scrub without a signal")
    func installTeardownDoesNotFire() {
        let probe = GuardProbe()
        let signalGuard = TempKeySignalGuard(
            scrub: { probe.recordScrub() },
            reraise: { probe.recordRaise($0) }
        )

        // Exercises the DispatchSource install/teardown path headlessly: no
        // signal is delivered, so the scrub must not run.
        signalGuard.install()
        signalGuard.teardown()

        #expect(probe.scrubCount == 0)
        #expect(probe.raisedSignals.isEmpty)
    }
}
