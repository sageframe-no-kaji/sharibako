import Foundation
import SharibakoCore

/// The shared-value question at Protect time (ho-06.10 AT-05).
///
/// A Protect decrypts every shared secret's value once, inside the key
/// handle it already holds, and compares each line it would protect for this
/// project with them — Check all's comparison
/// (``ProjectChecker/sharedID(matching:in:)``). A folder with a match is not
/// committed: it is held in ``WorkshopModel/pendingSharedValueMatches`` and
/// the window asks — **Use the shared secrets** (those lines use the shared
/// secret instead) or **Protect separately** (commit as planned). Nothing is
/// ever linked without asking (Do Not). Protect all holds each such folder
/// apart and asks once per project, after the rest commit.
///
/// The confirmation's buttons take the held Protect off the queue
/// synchronously at the tap (``takeSharedValueMatches()``) and pass it in —
/// the dialog's dismissal runs before the button's `Task` body (the ho-06.9
/// Forget-this-folder lesson), so the dismissal itself clears nothing, and a
/// second question waits until the first answer lands.
///
/// Kept in its own file, the `Conduit`/`Conduit+Remote.swift` split
/// precedent, under SwiftLint's `file_length` ceiling.
extension WorkshopModel {
    // MARK: - Types

    /// One line whose value equals a shared secret's.
    struct SharedValueMatch: Equatable, Sendable {
        /// The line's key.
        let key: String
        /// The shared secret with the same value.
        let sharedID: String
    }

    /// Where a Protect was asked from — how it lands once committed.
    enum ProtectOrigin: Equatable {
        /// **Protect this line**: the line stays selected afterwards.
        case line(key: String)
        /// **Protect N secrets** on one page.
        case page
        /// **Protect all** under Not protected.
        case all
    }

    /// A Protect held back because lines to protect for this project hold a
    /// shared secret's value, awaiting the user's answer.
    struct SharedValueMatches: Equatable {
        /// The Protect as planned.
        let plan: ProtectPlan
        /// The lines whose value equals a shared secret's, in plan order.
        let matches: [SharedValueMatch]
        /// Where the Protect was asked from.
        let origin: ProtectOrigin

        /// The plan with every matched line using its shared secret instead
        /// of a value of its own — **Use the shared secrets**.
        var planUsingShared: ProtectPlan {
            var shared: [String: String] = [:]
            for match in matches {
                shared[match.key] = match.sharedID
            }
            let decisions = plan.decisions.map { decision -> KeyDecision in
                guard case .importAsLocal(let key) = decision, let id = shared[key] else { return decision }
                return .linkToShared(key: key, sharedID: id)
            }
            return ProtectPlan(directory: plan.directory, scopeID: plan.scopeID, name: plan.name, decisions: decisions)
        }
    }

    // MARK: - The question's words

    /// The confirmation's title.
    static let sharedValueMatchesTitle = "Some values are already shared secrets"

    /// The button that has the matched lines use their shared secrets.
    static let useSharedSecretsButton = "Use the shared secrets"

    /// The button that protects every line with its own value, as planned.
    static let protectSeparatelyButton = "Protect separately"

    /// The confirmation's message: one line per match — "OPENAI_API_KEY has
    /// the same value as the shared secret openai-api-key" — headed by the
    /// project's name when Protect all asks about several projects in turn.
    static func sharedValueMatchesMessage(for held: SharedValueMatches) -> String {
        let lines = held.matches.map { "\($0.key) has the same value as the shared secret \($0.sharedID)" }
        let heading = held.origin == .all ? ["In \(held.plan.name):"] : []
        return (heading + lines).joined(separator: "\n")
    }

    /// The held Protect the window asks about now: the first in line, once no
    /// operation is running (Protect all finishes landing before it asks).
    var presentedSharedValueMatches: SharedValueMatches? {
        activity == nil ? pendingSharedValueMatches.first : nil
    }

    // MARK: - Intents

    /// Queues every Protect in `batch` held back on a shared value, asked
    /// from `origin`; `true` when any was.
    func holdForSharedValues(_ batch: ProtectBatch, origin: ProtectOrigin) -> Bool {
        for held in batch.held {
            pendingSharedValueMatches.append(SharedValueMatches(plan: held.plan, matches: held.matches, origin: origin))
        }
        if !batch.held.isEmpty, origin != .all {
            statusMessage = nil
        }
        return !batch.held.isEmpty
    }

    /// Takes the question on screen off the queue for the button that
    /// answered it, and marks a Protect as running so the next question waits
    /// for this one to land; `nil` while an operation runs or with nothing
    /// held.
    ///
    /// Called synchronously in the button action, before its `Task` (see the
    /// file header). The answer, ``answerSharedValueMatches(_:useShared:)``,
    /// clears ``activity`` when it lands.
    func takeSharedValueMatches() -> SharedValueMatches? {
        guard activity == nil, !pendingSharedValueMatches.isEmpty else { return nil }
        activity = .ingesting
        return pendingSharedValueMatches.removeFirst()
    }

    /// Answers `held`, taken by ``takeSharedValueMatches()``: commits it with
    /// the matched lines using their shared secrets (`useShared`), or as
    /// planned — one Touch ID, no second question — then lands it as its
    /// origin would have.
    func answerSharedValueMatches(_ held: SharedValueMatches, useShared: Bool) async {
        defer { activity = nil }
        guard case .open = vaultState else { return }
        let plan = useShared ? held.planUsingShared : held.plan
        let reason = "Protect secrets in \(plan.name)"
        guard let batch = await commitProtect([plan], reason: reason, checkSharedValues: false) else { return }
        await landProtect(batch, origin: held.origin)
    }

    /// Cancel: drops the question on screen without protecting anything, and
    /// says so.
    func cancelSharedValueMatches() {
        guard !pendingSharedValueMatches.isEmpty else { return }
        let held = pendingSharedValueMatches.removeFirst()
        statusMessage = "Nothing protected in \(held.plan.name)."
    }
}
