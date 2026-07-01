import Foundation

/// Network git operations for `Conduit`.
///
/// Kept in a separate file so the local-operations file stays visually focused
/// and both halves of the type body remain within SwiftLint's `type_body_length`
/// ceiling. Follows the `VaultCore+Encryption.swift` precedent.
extension Conduit {
    // MARK: - push

    /// Pushes local commits to the configured `origin` remote.
    ///
    /// Runs `git push origin HEAD`. If the remote is ahead of the local branch
    /// (non-fast-forward), returns ``PushResult/rejected(reason:)`` rather than
    /// throwing — that is a sync state, not a git failure.
    ///
    /// - Returns:
    ///   - ``PushResult/noRemote`` — no `origin` remote is configured.
    ///   - ``PushResult/upToDate`` — the remote already has these commits.
    ///   - ``PushResult/success(commitsPushed:)`` — commits transferred.
    ///   - ``PushResult/rejected(reason:)`` — remote rejected (non-fast-forward, etc.).
    /// - Throws: ``VaultError/gitInvocationFailed(exitCode:stderr:)`` for unexpected git errors.
    public func push() throws -> PushResult {
        guard try remoteURL() != nil else {
            return .noRemote
        }

        // Count commits ahead of upstream before pushing so we know how many got
        // transferred. Fetch first so @{upstream} is accurate.
        let fetchResult = try git(["fetch", "origin"])
        guard fetchResult.exitCode == 0 else {
            throw VaultError.gitInvocationFailed(
                exitCode: fetchResult.exitCode,
                stderr: fetchResult.stderr
            )
        }

        // Set upstream tracking if not already configured (first push after init + setRemote).
        let upstreamCheck = try git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"])
        let commitsPushed: Int
        if upstreamCheck.exitCode == 0 {
            let countResult = try git(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"])
            if countResult.exitCode == 0 {
                let parts = countResult.stdout
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: "\t")
                commitsPushed = parts.count >= 1 ? (Int(parts[0]) ?? 0) : 0
            } else {
                commitsPushed = 0
            }
        } else {
            // No upstream configured yet — count all commits on HEAD.
            let countResult = try git(["rev-list", "--count", "HEAD"])
            commitsPushed =
                countResult.exitCode == 0
                ? (Int(countResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
                : 0
        }

        let pushResult = try git(["push", "origin", "HEAD"])

        if pushResult.exitCode == 0 {
            let combined = pushResult.stdout + pushResult.stderr
            if combined.contains("Everything up-to-date") {
                return .upToDate
            }
            return .success(commitsPushed: commitsPushed)
        }

        let combined = pushResult.stdout + pushResult.stderr
        if combined.contains("rejected") || combined.contains("non-fast-forward") {
            return .rejected(reason: pushResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        throw VaultError.gitInvocationFailed(exitCode: pushResult.exitCode, stderr: pushResult.stderr)
    }

    // MARK: - pull

    /// Pulls commits from the configured `origin` remote.
    ///
    /// Uses `--no-rebase --no-ff` to force a merge strategy so that conflicts
    /// are surface-able and always produce `git merge --abort`-able state.
    ///
    /// On conflict, immediately runs `git merge --abort` and returns
    /// ``PullResult/abortedConflict(conflicts:)`` — the vault is always left in
    /// a clean state after `pull()` returns, whether or not the pull succeeded.
    ///
    /// - Returns:
    ///   - ``PullResult/noRemote`` — no `origin` remote is configured.
    ///   - ``PullResult/upToDate`` — local branch already has all remote commits.
    ///   - ``PullResult/success(commitsPulled:)`` — commits received.
    ///   - ``PullResult/abortedConflict(conflicts:)`` — merge conflict; merge aborted.
    /// - Throws: ``VaultError/gitInvocationFailed(exitCode:stderr:)`` for unexpected git errors.
    public func pull() throws -> PullResult {
        guard try remoteURL() != nil else {
            return .noRemote
        }

        // Fetch to update remote-tracking refs and @{upstream}.
        let fetchResult = try git(["fetch", "origin"])
        guard fetchResult.exitCode == 0 else {
            throw VaultError.gitInvocationFailed(
                exitCode: fetchResult.exitCode,
                stderr: fetchResult.stderr
            )
        }

        // Ensure upstream tracking branch is set so @{upstream} resolves.
        let upstreamCheck = try git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"])
        if upstreamCheck.exitCode != 0 {
            // Set tracking to origin/main (first-time clone scenario).
            let branchName = try currentBranchName()
            _ = try git(["branch", "--set-upstream-to=origin/\(branchName)", branchName])
        }

        // Check how many commits the remote is ahead.
        let countResult = try git(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"])
        guard countResult.exitCode == 0 else {
            throw VaultError.gitInvocationFailed(
                exitCode: countResult.exitCode,
                stderr: countResult.stderr
            )
        }
        let parts = countResult.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t")
        let remoteBehind = parts.count >= 2 ? (Int(parts[1]) ?? 0) : 0
        guard remoteBehind > 0 else {
            return .upToDate
        }
        let commitsPulled = remoteBehind

        let pullResult = try git(["pull", "--no-rebase", "--no-ff", "origin"])

        if pullResult.exitCode == 0 {
            return .success(commitsPulled: commitsPulled)
        }

        // Check for merge conflict in stdout (git 2.x writes CONFLICT lines to stdout).
        let combined = pullResult.stdout + pullResult.stderr
        guard combined.contains("CONFLICT") else {
            throw VaultError.gitInvocationFailed(exitCode: pullResult.exitCode, stderr: pullResult.stderr)
        }

        // Parse conflicting file paths from "CONFLICT (content): Merge conflict in <path>"
        let conflicts = try parseConflicts(from: pullResult.stdout)

        // Always abort — vault must be clean when pull() returns.
        _ = try git(["merge", "--abort"])

        return .abortedConflict(conflicts: conflicts)
    }

    // MARK: - Private helpers

    /// Returns the short name of the current branch (e.g. `"main"`).
    private func currentBranchName() throws -> String {
        let result = try git(["rev-parse", "--abbrev-ref", "HEAD"])
        guard result.exitCode == 0 else {
            throw VaultError.gitInvocationFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parses `CONFLICT (content): Merge conflict in <relPath>` lines from pull output
    /// and builds `[ConflictedFile]` with absolute paths and stage-2/3 SHAs.
    private func parseConflicts(from output: String) throws -> [ConflictedFile] {
        var files: [ConflictedFile] = []
        let conflictPrefix = "CONFLICT (content): Merge conflict in "

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let lineStr = String(line)
            guard lineStr.hasPrefix(conflictPrefix) else { continue }
            let relativePath = String(lineStr.dropFirst(conflictPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !relativePath.isEmpty else { continue }

            let absoluteURL = vaultURL.appendingPathComponent(relativePath)

            // git ls-files --stage <path> produces lines like:
            // <mode> <sha> <stage>\t<path>
            // Stage 2 = ours (local), stage 3 = theirs (remote).
            let stageResult = try git(["ls-files", "--stage", relativePath])
            let localSHA = extractStageSHA(from: stageResult.stdout, stage: 2)
            let remoteSHA = extractStageSHA(from: stageResult.stdout, stage: 3)

            files.append(
                ConflictedFile(
                    path: absoluteURL,
                    localSHA: localSHA,
                    remoteSHA: remoteSHA
                ))
        }

        return files
    }

    /// Extracts the git object SHA for a given stage number from `git ls-files --stage` output.
    ///
    /// Each line is `<mode> <sha> <stage>\t<path>`.
    private func extractStageSHA(from output: String, stage: Int) -> String {
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let lineStr = String(line)
            // Split on tab first to isolate the metadata prefix.
            let tabParts = lineStr.split(separator: "\t", maxSplits: 1)
            guard tabParts.count >= 1 else { continue }
            let metaPart = String(tabParts[0])
            let metaFields = metaPart.split(separator: " ")
            // metaFields: [mode, sha, stageNumber]
            guard metaFields.count >= 3, let stageNum = Int(metaFields[2]), stageNum == stage else {
                continue
            }
            return String(metaFields[1])
        }
        return ""
    }
}
