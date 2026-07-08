import Foundation

/// Replaces the current process image with the target command via `execve(2)`.
///
/// This is `sharibako run`'s terminal act (ho-04.13): once the scope is decrypted,
/// the environment composed, and the age-key handle released, the wrapper *becomes*
/// the command. No parent process survives once the child starts, so the child
/// inherits the wrapper's PID, process group, controlling terminal, and stdio —
/// every terminal signal (Ctrl-C, Ctrl-\), every stdin read, and the exit code are
/// native, with zero signal-handling code anywhere in `run`. This is the idiomatic
/// Unix wrapper pattern (`env`, `nohup`, `exec`, `sudo -E`): do the one job, then
/// get out of the way.
///
/// It supersedes the ho-04.12 signal-forwarding parent (pinned at tag
/// `parked/run-signal-forwarder`), which emulated a terminal by trapping and
/// relaying signals to a `Process`-spawned child sitting in its own process group.
///
/// Coverage-excluded (see ci.yml): `execve` on success never returns, so the
/// success path cannot run in a test without replacing the test runner; the
/// `chdir`/`execve` failure branches throw but are exercised only by the dogfood
/// gate (a real terminal). The tested decision logic — scope resolution, decrypt,
/// env composition — lives in ``RunCommand/_run(cwd:feedback:)``, which returns the
/// composed `RunOutcome.ready` instead of exec-ing, so it stays in-process testable.
enum ExecReplace {
    /// Replaces the process image with `command`, running in `cwd`.
    ///
    /// `chdir`s into `cwd`, then `execve`s `/usr/bin/env` with `command` and the
    /// composed `environment`. Returns only by throwing: on success the process
    /// image is replaced and control never comes back.
    ///
    /// - Parameters:
    ///   - command: The command and its arguments, passed through to `/usr/bin/env`
    ///     as-is — a leading `--` from `.captureForPassthrough` is consumed by `env`,
    ///     matching the prior `Process.arguments = command` behavior.
    ///   - environment: The merged child environment, emitted as `KEY=VALUE` pairs.
    ///   - cwd: The directory to run in. `execve` takes no working directory, so we
    ///     `chdir` first; a missing directory surfaces here as ``CLIError/runSpawnFailed``.
    /// - Throws: ``CLIError/runSpawnFailed`` when `chdir` or `execve` fails. A missing
    ///   *child* command is not a failure here — it surfaces as `/usr/bin/env` exiting
    ///   127, exactly as before.
    static func exec(command: [String], environment: [String: String], cwd: URL) throws -> Never {
        guard chdir(cwd.path) == 0 else {
            throw CLIError.runSpawnFailed(
                command: command.first ?? "", underlying: "chdir(\(cwd.path)): \(errnoMessage())"
            )
        }

        // /usr/bin/env resolves bare command names (npm, python) on PATH and execs
        // with the composed environment. argv[0] is the env path by convention.
        let argv = ["/usr/bin/env"] + command
        let envp = environment.map { "\($0.key)=\($0.value)" }

        // NUL-terminated C-string arrays. strdup copies each onto the heap; the
        // allocations are intentionally never freed — on success execve discards the
        // entire address space, and on failure the process throws and exits
        // immediately, so this one-shot "leak" is correct, not a bug.
        let cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        let cEnvp: [UnsafeMutablePointer<CChar>?] = envp.map { strdup($0) } + [nil]

        execve("/usr/bin/env", cArgv, cEnvp)

        // Reached only if execve itself failed (e.g. /usr/bin/env is missing).
        throw CLIError.runSpawnFailed(
            command: command.first ?? "", underlying: "execve(/usr/bin/env): \(errnoMessage())"
        )
    }

    /// The current `errno` as a human string.
    private static func errnoMessage() -> String {
        String(cString: strerror(errno))
    }
}
