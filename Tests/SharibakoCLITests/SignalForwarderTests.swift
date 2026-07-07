import Foundation
import Testing

@testable import SharibakoCLI

/// A `ChildController` that records what the forwarder asked of it, so the
/// forwarder's policy can be asserted without a live child or real signals.
private final class RecordingChildController: ChildController, @unchecked Sendable {
    private let lock = NSLock()
    private var sentSignals: [Int32] = []
    private var killed = false
    private let running: Bool

    init(running: Bool = true) {
        self.running = running
    }

    var isRunning: Bool { running }

    func send(_ signal: Int32) {
        lock.lock()
        sentSignals.append(signal)
        lock.unlock()
    }

    func forceKill() {
        lock.lock()
        killed = true
        lock.unlock()
    }

    var sent: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return sentSignals
    }

    var forceKilled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return killed
    }
}

/// Thread-safe collector for the stderr feedback lines the forwarder emits.
private final class LineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    var joined: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined()
    }
}

/// Policy tests for `SignalForwarder`, driven through the injected
/// ``ChildController`` seam (ho-04.12 D2–D4).
///
/// `receive(signal:)` is called directly rather than delivering real signals —
/// the live `install()`/timer plumbing stays coverage-excluded and is validated
/// by dogfooding. A large `grace` keeps the one-second countdown timer from
/// firing during these sub-millisecond tests; `teardown()` cancels it.
@Suite("SignalForwarder policy")
struct SignalForwarderTests {
    /// The forwarder plus the seams the assertions read back from.
    private struct Harness {
        let forwarder: SignalForwarder
        let controller: RecordingChildController
        let sink: LineSink
    }

    /// Builds a forwarder with a recorder, a capturing sink, and a grace long
    /// enough that no timer tick lands mid-test.
    private func makeForwarder(running: Bool = true) -> Harness {
        let controller = RecordingChildController(running: running)
        let sink = LineSink()
        let feedback = RunFeedback { sink.append($0) }
        let forwarder = SignalForwarder(controller: controller, grace: 300, feedback: feedback)
        return Harness(forwarder: forwarder, controller: controller, sink: sink)
    }

    @Test("SIGTERM is forwarded to the child with a forwarding line")
    func forwardsSIGTERM() {
        let harness = makeForwarder()
        harness.forwarder.receive(signal: SIGTERM)
        defer { harness.forwarder.teardown() }
        #expect(harness.controller.sent == [SIGTERM])
        #expect(harness.sink.joined.contains("forwarding SIGTERM"))
    }

    @Test("SIGINT is forwarded to the child")
    func forwardsSIGINT() {
        let harness = makeForwarder()
        harness.forwarder.receive(signal: SIGINT)
        defer { harness.forwarder.teardown() }
        // The child is in its own process group, so the terminal never signals
        // it directly — the wrapper's forward is its only SIGINT (dogfood
        // finding; ho-04.12 D2 reverted, ownership redesign in ho-04.13).
        #expect(harness.controller.sent == [SIGINT])
        #expect(harness.sink.joined.contains("forwarding SIGINT"))
        // First signal forwards and starts the countdown — no immediate kill.
        #expect(!harness.controller.forceKilled)
    }

    @Test("A second signal during the countdown escalates to SIGKILL immediately (ho-04.12 D3)")
    func secondSignalEscalates() {
        let harness = makeForwarder()
        harness.forwarder.receive(signal: SIGTERM)  // starts the countdown
        harness.forwarder.receive(signal: SIGINT)  // arrives while it's live → kill now
        defer { harness.forwarder.teardown() }
        #expect(harness.controller.forceKilled)
        #expect(harness.sink.joined.contains("sending SIGKILL"))
    }

    @Test("Escalation does not kill a child that has already exited (ho-04.12 D4 liveness)")
    func escalationRespectsLiveness() {
        let harness = makeForwarder(running: false)
        harness.forwarder.receive(signal: SIGINT)  // starts the countdown
        harness.forwarder.receive(signal: SIGINT)  // would escalate, but child is gone
        defer { harness.forwarder.teardown() }
        #expect(!harness.controller.forceKilled)
        #expect(!harness.sink.joined.contains("sending SIGKILL"))
    }
}
