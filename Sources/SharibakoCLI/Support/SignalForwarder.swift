import Dispatch
import Foundation

/// Forwards terminating signals from the `run` wrapper to its child process.
///
/// On `install()`, sets SIGINT/SIGTERM/SIGHUP to `SIG_IGN` at the process level (so the
/// default action doesn't fire) and observes each through a `DispatchSourceSignal`. When
/// one arrives, it forwards the same signal to the child's PID, waits a grace period, then
/// sends `SIGKILL` if the child is still alive. `teardown()` cancels the sources and
/// restores the prior dispositions.
///
/// This is live process plumbing — there is no headless way to raise a real terminating
/// signal at the test process without polluting the parallel test runner, so `run`'s tests
/// disable it (`forwardSignals: false`) and it is coverage-excluded. The termination
/// *mapping* it feeds (exit code vs. `128 + signum`) is tested through a child that
/// signals itself. Validated by dogfooding against a real dev server.
///
/// Liveness is probed with `kill(pid, 0)` rather than by holding the `Process` value, so
/// the type stays `Sendable`-clean and the handlers capture only value types.
final class SignalForwarder: @unchecked Sendable {
    private let childPID: pid_t
    private let grace: TimeInterval
    private let forwarded: [Int32] = [SIGINT, SIGTERM, SIGHUP]
    private var sources: [DispatchSourceSignal] = []
    private var previous: [Int32: sig_t] = [:]

    /// - Parameters:
    ///   - childPID: The spawned child's process identifier.
    ///   - grace: Seconds to wait after forwarding before escalating to `SIGKILL`.
    init(childPID: pid_t, grace: TimeInterval = 5) {
        self.childPID = childPID
        self.grace = grace
    }

    func install() {
        for sig in forwarded {
            // Ignore at the process level so the dispatch source receives the signal
            // instead of the default terminating action firing on the wrapper.
            if let prior = signal(sig, SIG_IGN) { previous[sig] = prior }
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            let childPID = childPID
            let grace = grace
            source.setEventHandler {
                kill(childPID, sig)
                DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
                    // kill(pid, 0) probes liveness without delivering a signal.
                    if kill(childPID, 0) == 0 { kill(childPID, SIGKILL) }
                }
            }
            source.resume()
            sources.append(source)
        }
    }

    func teardown() {
        for source in sources { source.cancel() }
        sources.removeAll()
        for (sig, prior) in previous { signal(sig, prior) }
        previous.removeAll()
    }
}
