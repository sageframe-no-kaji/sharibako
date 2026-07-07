import Dispatch
import Foundation

/// The child-process operations `SignalForwarder` performs, abstracted so the
/// production forwarder routes them through a live `Process` — which cannot
/// alias a PID the kernel has recycled between grace expiry and delivery
/// (ho-04.12 D4) — while tests inject a recorder and drive the forwarder's
/// policy without delivering real signals (the ho-04.5 seam precedent).
protocol ChildController: Sendable {
    /// Whether the child is still running. Routed through the `Process` object,
    /// never a raw `kill(pid, 0)` probe against a possibly-recycled PID.
    var isRunning: Bool { get }

    /// Delivers `signal` to the child. Called only for the forwarded set
    /// (SIGTERM/SIGHUP/SIGQUIT); a no-op once the child has exited.
    func send(_ signal: Int32)

    /// Force-kills the child with SIGKILL, but only while it is still running.
    func forceKill()
}

/// Production ``ChildController`` backed by a live `Process`.
final class ProcessChildController: ChildController, @unchecked Sendable {
    // @unchecked Sendable: the wrapped `Process` is only queried for `isRunning`
    // and asked to signal/terminate — operations Foundation permits from any
    // thread. The forwarder touches it from dispatch queues while the main
    // thread sits in `waitUntilExit()`; no mutable state is shared beyond what
    // `Process` itself synchronizes.
    private let process: Process

    init(_ process: Process) {
        self.process = process
    }

    var isRunning: Bool { process.isRunning }

    func send(_ signal: Int32) {
        guard process.isRunning else { return }
        // terminate() is Foundation's SIGTERM path through the Process object;
        // SIGHUP/SIGQUIT have no such convenience, so they go through raw kill —
        // guarded by isRunning, which is the recycled-PID protection D4 asks for.
        if signal == SIGTERM {
            process.terminate()
        } else {
            kill(process.processIdentifier, signal)
        }
    }

    func forceKill() {
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }
}

/// Bridges terminating signals from the `run` wrapper to its child, with stderr
/// feedback across the grace window.
///
/// On `install()` the wrapper ignores its terminating signals at the process
/// level (so their default action doesn't fire on the wrapper) and observes each
/// through a `DispatchSourceSignal`. The policy that runs per signal lives in
/// ``receive(signal:)``:
///
/// - **SIGINT, SIGTERM, and SIGHUP are forwarded to the child.** Foundation's
///   `Process` spawns the child in its own process group, off the terminal's
///   foreground group, so a terminal Ctrl-C does NOT reach the child (verified
///   by the ho-04.12 dogfood gate) — the wrapper's forward is the child's only
///   SIGINT. (ho-04.12 D2 proposed dropping SIGINT on the premise the kernel
///   already delivered it; the dogfood disproved that premise, D2 was reverted,
///   and the signal-ownership redesign moved to ho-04.13.)
/// - **A signal arriving while the countdown is live escalates immediately to
///   SIGKILL (ho-04.12 D3).** Mashing Ctrl-C means "die now", not "postpone" —
///   the previous code cancel-and-restarted the countdown, deferring SIGKILL
///   indefinitely.
/// - **Liveness and the kill go through the ``ChildController`` (ho-04.12 D4),**
///   which is backed by the `Process` object in production, so neither can
///   alias a recycled PID.
///
/// This is live process plumbing: `install()`/`teardown()` and the real-time
/// countdown timer only run when a live child receives real signals, and
/// sending a signal to the test process would kill the parallel runner. That
/// surface stays coverage-excluded (see ci.yml). The *policy* — which signals
/// forward, and what a second signal does — is verified in `SignalForwarderTests`
/// by driving ``receive(signal:)`` through an injected recorder and a capturing
/// `RunFeedback`; the feedback *strings* are the pure `RunFeedback` formatters,
/// tested there.
final class SignalForwarder: @unchecked Sendable {
    /// Terminating signals the wrapper observes and forwards to the child.
    ///
    /// All three are relayed: the child is in its own process group, so the
    /// terminal never signals it directly. Signal ownership (process groups,
    /// which signals to forward) is redesigned in ho-04.13.
    private static let forwarded: [Int32] = [SIGINT, SIGTERM, SIGHUP]

    private let controller: ChildController
    private let grace: TimeInterval
    private let feedback: RunFeedback
    private var sources: [DispatchSourceSignal] = []
    /// Prior dispositions, keyed by signal.
    ///
    /// A `nil` value records SIG_DFL — it must still be restored on teardown.
    private var previous: [Int32: sig_t?] = [:]

    /// Countdown state, touched only on `countdownQueue`.
    private var countdown: DispatchSourceTimer?
    private var countdownRemaining = 0
    private var countdownActive = false
    private let countdownQueue = DispatchQueue(label: "net.sageframe.sharibako.run.countdown")

    /// - Parameters:
    ///   - controller: The child-process control seam (production wraps `Process`).
    ///   - grace: Seconds to wait after the first signal before escalating to SIGKILL.
    ///   - feedback: Stderr sink for the forwarding/countdown/SIGKILL lines.
    init(controller: ChildController, grace: TimeInterval = 5, feedback: RunFeedback = .disabled) {
        self.controller = controller
        self.grace = grace
        self.feedback = feedback
    }

    func install() {
        for sig in Self.forwarded {
            // Ignore at the process level so the dispatch source receives the
            // signal instead of the default terminating action firing on the
            // wrapper. updateValue (not subscript) so a nil result — SIG_DFL —
            // is stored rather than dropped; teardown must restore defaults too.
            previous.updateValue(signal(sig, SIG_IGN), forKey: sig)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { [weak self] in
                self?.receive(signal: sig)
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
            countdownActive = false
        }
        for (sig, prior) in previous { signal(sig, prior ?? SIG_DFL) }
        previous.removeAll()
    }

    /// The forwarder's per-signal policy.
    ///
    /// The first signal forwards to the child and starts the countdown; any
    /// signal arriving while the countdown is already live escalates straight to
    /// SIGKILL.
    ///
    /// Serialized on `countdownQueue` so a burst of signals can't interleave the
    /// active-check with the countdown start.
    func receive(signal sig: Int32) {
        countdownQueue.sync {
            if countdownActive {
                killNowLocked()
                return
            }
            feedback.emit(RunFeedback.forwardingLine(signal: sig))
            controller.send(sig)
            startCountdownLocked()
        }
    }

    /// Starts the one-second SIGKILL countdown.
    ///
    /// Caller holds `countdownQueue`.
    private func startCountdownLocked() {
        countdownActive = true
        countdownRemaining = Int(grace.rounded())
        let timer = DispatchSource.makeTimerSource(queue: countdownQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        countdown = timer
        timer.resume()
    }

    /// Runs on `countdownQueue`: one tick down, escalate to SIGKILL at zero.
    private func tick() {
        countdownRemaining -= 1
        if countdownRemaining >= 1 {
            feedback.emit(RunFeedback.countdownLine(secondsRemaining: countdownRemaining))
        } else {
            killNowLocked()
        }
    }

    /// Cancels the countdown and force-kills the child if it is still running.
    /// Caller holds `countdownQueue` (either `receive`'s `sync` or a timer tick).
    private func killNowLocked() {
        countdown?.cancel()
        countdown = nil
        countdownActive = false
        if controller.isRunning {
            feedback.emit(RunFeedback.sigkillLine())
            controller.forceKill()
        }
    }
}
