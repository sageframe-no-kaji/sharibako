import Foundation
import Testing

@testable import SharibakoCLI

/// Tests for the `run` feedback formatter and the TTY/flag gate.
///
/// The startup-line formatter is pure and the gate is a pure `Bool`, so this suite
/// covers the feedback logic without a live process or a real terminal.
@Suite("RunFeedback")
struct RunFeedbackTests {
    // MARK: - Gate

    @Test("Gate: on for a TTY, off when redirected")
    func gateTTY() {
        #expect(RunFeedback.shouldEmit(json: false, verbose: false, isTTY: true))
        #expect(!RunFeedback.shouldEmit(json: false, verbose: false, isTTY: false))
    }

    @Test("Gate: --json suppresses even on a TTY")
    func gateJSONSuppresses() {
        #expect(!RunFeedback.shouldEmit(json: true, verbose: false, isTTY: true))
    }

    @Test("Gate: --verbose forces on even when redirected")
    func gateVerboseForces() {
        #expect(RunFeedback.shouldEmit(json: false, verbose: true, isTTY: false))
    }

    @Test("Gate: --json wins over --verbose")
    func gateJSONBeatsVerbose() {
        #expect(!RunFeedback.shouldEmit(json: true, verbose: true, isTTY: true))
    }

    // MARK: - Startup line

    @Test("Startup line names the scope and count, pluralizing correctly")
    func startupLineCounts() {
        #expect(
            RunFeedback.startupLine(scope: "diary", secretCount: 12, command: ["sh", "-c", "true"])
                == "sharibako: scope 'diary' — 12 secrets → sh -c true"
        )
        #expect(
            RunFeedback.startupLine(scope: "s", secretCount: 1, command: ["true"])
                == "sharibako: scope 's' — 1 secret → true"
        )
    }

    @Test("Startup line drops the passthrough -- separator for display")
    func startupLineDropsSeparator() {
        #expect(
            RunFeedback.startupLine(scope: "proj", secretCount: 2, command: ["--", "sh", "-c", "true"])
                == "sharibako: scope 'proj' — 2 secrets → sh -c true"
        )
    }

    @Test("Startup line reports zero secrets in place of the old empty-scope note")
    func startupLineZero() {
        #expect(
            RunFeedback.startupLine(scope: "empty", secretCount: 0, command: ["true"])
                == "sharibako: scope 'empty' — no secrets to inject → true"
        )
    }

    @Test("Startup line never contains a secret value or key name — count only")
    func startupLineNoLeak() {
        // The formatter takes only a count; it has no channel through which a value or
        // key name could appear. Assert the contract holds for representative inputs.
        let line = RunFeedback.startupLine(scope: "proj", secretCount: 3, command: ["node", "app.js"])
        #expect(!line.contains("sk-"))  // no API-key-shaped value
        #expect(line.contains("3 secrets"))
        #expect(line.contains("'proj'"))
    }

    // MARK: - Sinks

    @Test("standardError sink writes without throwing; disabled sink swallows")
    func productionSinks() {
        // stderr in the test runner is a plain pipe/file — writing is harmless
        // and exercises the production emitter body.
        RunFeedback.standardError.emit("sharibako-test: standardError sink probe")
        RunFeedback.disabled.emit("never seen")
    }
}
