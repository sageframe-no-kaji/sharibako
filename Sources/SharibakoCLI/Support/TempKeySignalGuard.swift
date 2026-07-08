import Dispatch
import Foundation

/// Scrubs a plaintext temp file if a fatal signal arrives during its lifetime,
/// then lets the signal kill the process as it would have anyway (ho-04.12 D1).
///
/// `KeychainAgeKeyProvider` writes the decrypted age key to a `0600` temp file
/// and scrubs it only on normal `release()`. A SIGINT/SIGTERM/SIGHUP/SIGQUIT in
/// that window — Ctrl-C during a Touch ID prompt, a `kill` from another
/// terminal — would otherwise fire the signal's default terminating action and
/// leave the plaintext key on disk (the limitation SECURITY.md disclosed since
/// the fable sweep). For the file's lifetime this guard traps those four
/// signals: it runs the injected `scrub`, restores the signal's default
/// disposition, and re-raises, so the process still dies of the same signal —
/// observably — but after the key is gone.
///
/// The trap is a `DispatchSourceSignal`, not a raw `sigaction` handler: the
/// handler runs on a normal dispatch queue, so it may call `FileManager` and
/// friends (a raw C signal handler is restricted to async-signal-safe calls,
/// which `scrubAndDelete` is not).
///
/// The scrub action and the re-raise are both injected, so a test can drive
/// ``handle(_:)`` directly — asserting the file is gone and the signal was
/// re-raised — without delivering a real signal to the test runner.
final class TempKeySignalGuard: @unchecked Sendable {
    /// The signals whose default action would leak the temp key: interactive
    /// interrupt, polite termination, terminal hang-up, and quit-with-core.
    private static let trapped: [Int32] = [SIGINT, SIGTERM, SIGHUP, SIGQUIT]

    private let scrub: @Sendable () -> Void
    private let reraise: @Sendable (Int32) -> Void

    private var sources: [DispatchSourceSignal] = []
    /// Prior dispositions, keyed by signal.
    ///
    /// A `nil` value records SIG_DFL — it must still be restored on ``teardown()``.
    private var previous: [Int32: sig_t?] = [:]

    /// Ensures the scrub-and-reraise runs at most once even if two signals race.
    private let fireLock = NSLock()
    private var fired = false

    /// - Parameters:
    ///   - scrub: Removes the plaintext key from disk. Runs on a dispatch queue,
    ///     so it may use `FileManager`.
    ///   - reraise: Re-delivers the signal after scrubbing. The default restores
    ///     the signal's default disposition and raises it, killing the process;
    ///     tests inject a recorder that captures the signal instead.
    init(
        scrub: @escaping @Sendable () -> Void,
        reraise: @escaping @Sendable (Int32) -> Void = { sig in
            signal(sig, SIG_DFL)
            raise(sig)
        }
    ) {
        self.scrub = scrub
        self.reraise = reraise
    }

    /// Ignores the trapped signals at the process level and observes each through
    /// a `DispatchSourceSignal`, so a delivery runs ``handle(_:)`` on a queue
    /// instead of firing the default terminating action on the wrapper.
    func install() {
        for sig in Self.trapped {
            // updateValue (not subscript) so a nil result — SIG_DFL — is stored
            // rather than dropped; teardown must restore defaults too.
            previous.updateValue(signal(sig, SIG_IGN), forKey: sig)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { [weak self] in self?.handle(sig) }
            source.resume()
            sources.append(source)
        }
    }

    /// Scrubs the temp file and re-raises `sig`.
    ///
    /// Idempotent — a second racing signal is dropped so the file is scrubbed
    /// exactly once.
    ///
    /// Factored out of the dispatch handler so tests can call it directly.
    func handle(_ sig: Int32) {
        fireLock.lock()
        let alreadyFired = fired
        fired = true
        fireLock.unlock()
        guard !alreadyFired else { return }
        scrub()
        reraise(sig)
    }

    /// Cancels the signal sources and restores the prior dispositions.
    ///
    /// Called from the handle's `release()` on normal completion; safe to call
    /// even if ``install()`` was never invoked (both collections are empty).
    func teardown() {
        for source in sources { source.cancel() }
        sources.removeAll()
        for (sig, prior) in previous { signal(sig, prior ?? SIG_DFL) }
        previous.removeAll()
    }
}
