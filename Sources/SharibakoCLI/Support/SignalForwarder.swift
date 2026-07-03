import Dispatch
import Foundation

/// Forwards terminating signals from the `run` wrapper to its child process, with
/// stderr feedback across the grace window.
///
/// On `install()`, sets SIGINT/SIGTERM/SIGHUP to `SIG_IGN` at the process level (so the
/// default action doesn't fire) and observes each through a `DispatchSourceSignal`. When
/// one arrives, it emits a `forwarding…` line, forwards the same signal to the child's
/// PID, and starts a one-second countdown that emits the seconds remaining until SIGKILL.
/// If the child outlives the grace period it emits the SIGKILL line and sends `SIGKILL`.
/// `teardown()` cancels the sources and the countdown and restores the prior dispositions —
/// so a child that exits promptly prints no stray ticks.
///
/// This is live process plumbing — there is no headless way to raise a real terminating
/// signal at the test process without polluting the parallel test runner, so `run`'s tests
/// disable it (`forwardSignals: false`) and it is coverage-excluded. The feedback *strings*
/// it emits are the pure `RunFeedback` formatters, tested there. Validated by dogfooding
/// against a real child.
///
/// Liveness is probed with `kill(pid, 0)` rather than by holding the `Process` value, so
/// the type stays `Sendable`-clean and the handlers capture only value types.
final class SignalForwarder: @unchecked Sendable {
    private let childPID: pid_t
    private let grace: TimeInterval
    private let feedback: RunFeedback
    private let forwarded: [Int32] = [SIGINT, SIGTERM, SIGHUP]
    private var sources: [DispatchSourceSignal] = []
    /// Prior dispositions, keyed by signal.
    ///
    /// A `nil` value records SIG_DFL — it must still be restored on teardown.
    private var previous: [Int32: sig_t?] = [:]

    /// Countdown state, touched only on `countdownQueue`.
    private var countdown: DispatchSourceTimer?
    private var countdownRemaining = 0
    private let countdownQueue = DispatchQueue(label: "net.sageframe.sharibako.run.countdown")

    /// - Parameters:
    ///   - childPID: The spawned child's process identifier.
    ///   - grace: Seconds to wait after forwarding before escalating to `SIGKILL`.
    ///   - feedback: Stderr sink for the forwarding/countdown/SIGKILL lines.
    init(childPID: pid_t, grace: TimeInterval = 5, feedback: RunFeedback = .disabled) {
        self.childPID = childPID
        self.grace = grace
        self.feedback = feedback
    }

    func install() {
        for sig in forwarded {
            // Ignore at the process level so the dispatch source receives the signal
            // instead of the default terminating action firing on the wrapper.
            // updateValue (not subscript) so a nil result — SIG_DFL — is stored
            // rather than dropped; teardown must restore defaults too.
            previous.updateValue(signal(sig, SIG_IGN), forKey: sig)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { [weak self] in
                self?.handle(signal: sig)
            }
            source.resume()
            sources.append(source)
        }
    }

    func teardown() {
        for source in sources { source.cancel() }
        sources.removeAll()
        countdownQueue.sync {
            countdown?.cancel()
            countdown = nil
        }
        for (sig, prior) in previous { signal(sig, prior ?? SIG_DFL) }
        previous.removeAll()
    }

    /// Runs on the signal source's queue: announce, forward, start the countdown.
    private func handle(signal sig: Int32) {
        feedback.emit(RunFeedback.forwardingLine(signal: sig))
        kill(childPID, sig)
        startCountdown()
    }

    private func startCountdown() {
        let timer = DispatchSource.makeTimerSource(queue: countdownQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        countdownQueue.sync {
            countdown?.cancel()
            countdownRemaining = Int(grace.rounded())
            countdown = timer
        }
        timer.resume()
    }

    /// Runs on `countdownQueue`: one tick down, escalate to SIGKILL at zero.
    private func tick() {
        countdownRemaining -= 1
        if countdownRemaining >= 1 {
            feedback.emit(RunFeedback.countdownLine(secondsRemaining: countdownRemaining))
        } else {
            countdown?.cancel()
            countdown = nil
            // kill(pid, 0) probes liveness without delivering a signal.
            if kill(childPID, 0) == 0 {
                feedback.emit(RunFeedback.sigkillLine())
                kill(childPID, SIGKILL)
            }
        }
    }
}
