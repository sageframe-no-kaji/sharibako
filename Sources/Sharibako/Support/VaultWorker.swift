import Foundation

/// A serial off-main execution domain for blocking `SharibakoCore` work
/// (ho-06.1 Decision 1).
///
/// The Workshop's long operations — scan, materialize, sync — walk directory
/// trees and shell out to `git`/`age`. Running them on the main actor
/// beach-balls the window (the ho-05 gate proved the synchronous posture false
/// for exactly this work). `VaultWorker` is a bare actor whose only job is to
/// run a `Sendable` closure off the main thread. Because an actor serializes
/// its own execution, two operations submitted to the same worker can never
/// interleave — the "one vault operation at a time" property the synchronous
/// posture gave for free survives the move off-main by construction, not by a
/// busy-flag convention future code must remember.
///
/// The worker has no vault knowledge and no state beyond what serial execution
/// needs: it is the isolation domain, not the logic. `WorkshopModel` owns the
/// state, acquires the age key on the main actor, and hands only `Sendable`
/// values (the `AgeKeyHandle`'s URL, the vault URL, scan roots) across.
actor VaultWorker {
    /// Runs `work` on the worker's executor and returns (or rethrows) its result.
    ///
    /// The `await` at the call site is the only place execution hops off the
    /// main actor; the closure runs to completion on the worker before control
    /// returns. `rethrows` preserves the closure's throwing behaviour so the
    /// caller's `do/catch` maps `VaultError` exactly as it did synchronously.
    func run<T: Sendable>(_ work: @Sendable () throws -> T) rethrows -> T {
        try work()
    }
}
