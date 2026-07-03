import Foundation

/// Git wrapper that gives a Sharibako vault directory sync capabilities.
///
/// `Conduit` is a value type parallel to ``VaultCore``. It knows nothing about
/// secrets — every operation it performs is a file-level git operation on the
/// vault directory. Local operations (init, commit, status, identity, remote
/// config) are implemented here; network operations (`push`, `pull`) are
/// added in AT-02.
///
/// All git invocations run with the vault directory as the working directory
/// via the internal ``git(_:)`` helper, which calls ``Shell/run(_:_:workingDirectory:)``.
public struct Conduit: Sendable {
    /// Absolute URL of the vault root that git tracks.
    public let vaultURL: URL

    /// Binds to an existing vault directory.
    ///
    /// Does not verify the directory is a git repository. A vault that hasn't
    /// been initialized yet is valid — call ``initializeRepository()`` first.
    /// Missing `.git/` on subsequent operations surfaces as
    /// ``VaultError/gitInvocationFailed(exitCode:stderr:)`` with git's own message.
    ///
    /// - Parameter vaultURL: Absolute URL of the vault root.
    /// - Throws: ``VaultError/vaultNotFound(path:)`` if the directory does not exist.
    public init(vaultURL: URL) throws {
        try Self.assertVaultDirectoryExists(vaultURL)
        self.vaultURL = vaultURL
    }

    // MARK: - Repository setup

    /// Initializes a git repository inside the vault directory.
    ///
    /// Runs `git init` when `.git/` is absent. Idempotent — if `.git/` already
    /// exists, returns without running any git command.
    ///
    /// - Throws: ``VaultError/gitInvocationFailed(exitCode:stderr:)`` if `git init` exits non-zero.
    public func initializeRepository() throws {
        let gitDir = vaultURL.appendingPathComponent(".git")
        guard !FileManager.default.fileExists(atPath: gitDir.path) else {
            return
        }
        let result = try git(["init"])
        guard result.exitCode == 0 else {
            throw VaultError.gitInvocationFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    /// Sets the committer identity in the vault's local git config.
    ///
    /// Writes `user.name` and `user.email` to `.git/config` using `--local` scope
    /// so the global `~/.gitconfig` is not modified. Runs two separate
    /// `git config` invocations; a failure on the second leaves the first written.
    ///
    /// - Parameters:
    ///   - name: Human-readable committer name.
    ///   - email: Committer email address.
    /// - Throws: ``VaultError/gitInvocationFailed(exitCode:stderr:)`` if either invocation exits non-zero.
    public func setIdentity(name: String, email: String) throws {
        let nameResult = try git(["config", "--local", "user.name", name])
        guard nameResult.exitCode == 0 else {
            throw VaultError.gitInvocationFailed(exitCode: nameResult.exitCode, stderr: nameResult.stderr)
        }
        let emailResult = try git(["config", "--local", "user.email", email])
        guard emailResult.exitCode == 0 else {
            throw VaultError.gitInvocationFailed(exitCode: emailResult.exitCode, stderr: emailResult.stderr)
        }
    }

    // MARK: - Remote configuration

    /// Sets or updates the `origin` remote URL.
    ///
    /// Probes for an existing `origin` with `git remote get-url origin`. If one
    /// exists, runs `git remote set-url -- origin <url>`; otherwise runs
    /// `git remote add -- origin <url>`. The `--` separator keeps a URL that
    /// begins with `-` from being parsed as a git option.
    ///
    /// - Parameter url: The remote URL to set (SSH or HTTPS).
    /// - Throws: ``VaultError/remoteURLRejected(url:reason:)`` for a transport
    ///   outside the allowlist; ``VaultError/gitInvocationFailed(exitCode:stderr:)``
    ///   if git exits non-zero for reasons other than "no such remote".
    public func setRemote(_ url: String) throws {
        try Self.validateRemoteURL(url)
        let probe = try git(["remote", "get-url", "origin"])
        if probe.exitCode == 0 {
            let result = try git(["remote", "set-url", "--", "origin", url])
            guard result.exitCode == 0 else {
                throw VaultError.gitInvocationFailed(exitCode: result.exitCode, stderr: result.stderr)
            }
        } else {
            let result = try git(["remote", "add", "--", "origin", url])
            guard result.exitCode == 0 else {
                throw VaultError.gitInvocationFailed(exitCode: result.exitCode, stderr: result.stderr)
            }
        }
    }

    /// Transport allowlist for remote URLs (ho-04.9, defense-in-depth).
    ///
    /// git supports transport helpers (`ext::<command>`, `fd::<n>`) that turn
    /// a remote "URL" into command execution. `setRemote` isn't currently
    /// reachable from git-synced vault data, but the allowlist makes the safe
    /// property structural rather than incidental. Allowed: `https://`,
    /// `ssh://`, `file://`, absolute local paths, and scp-style
    /// `user@host:path`.
    private static func validateRemoteURL(_ url: String) throws {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw VaultError.remoteURLRejected(url: url, reason: "empty URL")
        }
        // Explicit-scheme and local-path transports.
        for prefix in ["https://", "ssh://", "file://"] where trimmed.hasPrefix(prefix) {
            return
        }
        if trimmed.hasPrefix("/") {
            return  // absolute local path (tests, local mirrors)
        }
        // Transport helpers are the command-execution vector — reject before
        // the scp-style check, which a helper URL would otherwise satisfy.
        guard !trimmed.contains("::") else {
            throw VaultError.remoteURLRejected(
                url: url,
                reason: "git transport helpers (ext::, fd::) are not allowed"
            )
        }
        // scp-style user@host:path — a colon, but no scheme separator.
        let colon = trimmed.firstIndex(of: ":")
        if let colon, colon != trimmed.startIndex, !trimmed.contains("://") {
            return
        }
        throw VaultError.remoteURLRejected(
            url: url,
            reason: "unrecognized transport — allowed: https://, ssh://, scp-style, or a local path"
        )
    }

    /// Returns the configured `origin` remote URL, or `nil` if no remote is set.
    ///
    /// A non-zero exit from `git remote get-url origin` is treated as "no remote"
    /// and returns `nil`. Only throws when the shell itself fails to launch git.
    ///
    /// - Returns: The trimmed URL string, or `nil`.
    /// - Throws: ``VaultError/shellNotFound(name:)`` if `git` is not on PATH.
    public func remoteURL() throws -> String? {
        let result = try git(["remote", "get-url", "origin"])
        guard result.exitCode == 0 else {
            return nil
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Status

    /// Returns the current working-tree and branch state of the vault repository.
    ///
    /// Runs `git status --porcelain=v2 --branch` and parses the output into a
    /// ``StatusResult``. Relative paths in the output are expanded to absolute
    /// paths by joining with ``vaultURL``.
    ///
    /// - Returns: A ``StatusResult`` describing the repository state.
    /// - Throws: ``VaultError/gitInvocationFailed(exitCode:stderr:)`` if git exits non-zero
    ///   or the directory is not a git repository.
    public func status() throws -> StatusResult {
        let result = try git(["status", "--porcelain=v2", "--branch"])
        guard result.exitCode == 0 else {
            throw VaultError.gitInvocationFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        return try parseStatusOutput(result.stdout)
    }

    // MARK: - Commit

    /// Stages all vault-directory changes and creates a commit.
    ///
    /// Runs `git add -A` at the vault root — excluding encrypt-path staging
    /// leftovers (``VaultLayout/stagingPrefix``), ciphertext-only crash strays
    /// that stay visible in `git status` but must never sync — then
    /// `git commit -m <message>`.
    /// If there is nothing to commit (exit code 1 with git's standard message),
    /// returns ``CommitResult/nothingToCommit`` without throwing. On success,
    /// resolves the new HEAD SHA via `git rev-parse HEAD`.
    ///
    /// - Parameter message: The commit message (single-line or multi-line).
    /// - Returns: ``CommitResult/success(sha:)`` with the new commit's SHA, or
    ///   ``CommitResult/nothingToCommit``.
    /// - Throws: ``VaultError/gitInvocationFailed(exitCode:stderr:)`` for any other failure.
    public func commit(message: String) throws -> CommitResult {
        // Default (non-glob) pathspec matching runs fnmatch WITHOUT
        // FNM_PATHNAME, so the leading `*` crosses directory separators —
        // one exclude covers staging strays at the root, in shared/, and in
        // every scope directory.
        let addResult = try git(["add", "-A", "--", ".", ":(exclude)*\(VaultLayout.stagingPrefix)*"])
        guard addResult.exitCode == 0 else {
            throw VaultError.gitInvocationFailed(exitCode: addResult.exitCode, stderr: addResult.stderr)
        }

        let commitResult = try git(["commit", "-m", message])
        if commitResult.exitCode != 0 {
            let output = (commitResult.stdout + commitResult.stderr).lowercased()
            if output.contains("nothing to commit") || output.contains("nothing added to commit") {
                return .nothingToCommit
            }
            throw VaultError.gitInvocationFailed(exitCode: commitResult.exitCode, stderr: commitResult.stderr)
        }

        let revResult = try git(["rev-parse", "HEAD"])
        guard revResult.exitCode == 0 else {
            throw VaultError.gitInvocationFailed(exitCode: revResult.exitCode, stderr: revResult.stderr)
        }
        let sha = revResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(sha: sha)
    }

    // MARK: - Private helpers

    private static func assertVaultDirectoryExists(_ vaultURL: URL) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: vaultURL.path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            throw VaultError.vaultNotFound(path: vaultURL)
        }
    }

    /// Runs a git command inside the vault directory.
    ///
    /// All git invocations in `Conduit` go through this helper so the working
    /// directory is always set to ``vaultURL``. Non-zero exits are NOT thrown
    /// here — the caller interprets them (some are informational, not errors).
    ///
    /// Runs with `LC_ALL=C` so the human-readable messages some callers match
    /// against ("nothing to commit", "Everything up-to-date", "rejected") are
    /// never localized out from under them.
    ///
    /// `internal` (not `private`) so that extension files in the same module
    /// (`Conduit+Remote.swift`) can share this single invocation surface.
    internal func git(_ arguments: [String]) throws -> ShellResult {
        let binary = try Shell.findExecutable("git")
        return try Shell.run(
            binary,
            arguments,
            workingDirectory: vaultURL,
            environmentOverrides: ["LC_ALL": "C"]
        )
    }

    /// Parses the output of `git status --porcelain=v2 --branch`.
    ///
    /// Format reference: https://git-scm.com/docs/git-status#_porcelain_format_version_2
    private func parseStatusOutput(_ output: String) throws -> StatusResult {
        var ahead = 0
        var behind = 0
        var hasRemote = false
        var untrackedFiles: [URL] = []
        var modifiedFiles: [URL] = []
        var deletedFiles: [URL] = []

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineStr = String(line)

            if lineStr.hasPrefix("# branch.ab ") {
                // Format: # branch.ab +<ahead> -<behind>
                let parts = lineStr.dropFirst("# branch.ab ".count).split(separator: " ")
                if parts.count >= 2 {
                    if let aheadVal = Int(parts[0].dropFirst()), let behindVal = Int(parts[1].dropFirst()) {
                        ahead = aheadVal
                        behind = behindVal
                    }
                }
            } else if lineStr.hasPrefix("# branch.upstream ") {
                hasRemote = true
            } else if lineStr.hasPrefix("? ") {
                // Untracked file: "? <path>"
                let path = String(lineStr.dropFirst(2))
                untrackedFiles.append(vaultURL.appendingPathComponent(path))
            } else if lineStr.hasPrefix("1 ") {
                // Ordinary changed entry: "1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>"
                // XY is two-character status (index + worktree)
                let fields = lineStr.split(separator: " ", maxSplits: 8)
                guard fields.count >= 9 else { continue }
                let xy = String(fields[1])
                let path = String(fields[8])
                let absURL = vaultURL.appendingPathComponent(path)
                // 'D' in index (X) or worktree (Y) means deleted
                if xy.hasPrefix("D") || xy.hasSuffix("D") {
                    deletedFiles.append(absURL)
                } else {
                    modifiedFiles.append(absURL)
                }
            } else if lineStr.hasPrefix("2 ") {
                // Renamed/copied entry: treat as modified
                let fields = lineStr.split(separator: " ", maxSplits: 9)
                guard fields.count >= 10 else { continue }
                // Path is the last field; rename format appends "\t<orig>" but we only need the new path
                let pathField = String(fields[9])
                let newPath = pathField.split(separator: "\t").first.map(String.init) ?? pathField
                modifiedFiles.append(vaultURL.appendingPathComponent(newPath))
            }
        }

        let dirty = !untrackedFiles.isEmpty || !modifiedFiles.isEmpty || !deletedFiles.isEmpty

        return StatusResult(
            dirty: dirty,
            untrackedFiles: untrackedFiles,
            modifiedFiles: modifiedFiles,
            deletedFiles: deletedFiles,
            ahead: ahead,
            behind: behind,
            hasRemote: hasRemote
        )
    }
}
