import Foundation

/// Result of a ``Conduit/commit(message:)`` call.
public enum CommitResult: Sendable, Equatable {
    /// A commit was created with the given SHA.
    case success(sha: String)
    /// No tracked or untracked changes were present; no commit was made.
    case nothingToCommit
}

/// Result of a ``Conduit/push()`` call (implemented in AT-02).
public enum PushResult: Sendable, Equatable {
    /// The push succeeded; `commitsPushed` counts the commits transferred.
    case success(commitsPushed: Int)
    /// The remote was already up to date; nothing was transferred.
    case upToDate
    /// No `origin` remote is configured on this repository.
    case noRemote
    /// The remote rejected the push (non-fast-forward, auth failure, etc.).
    case rejected(reason: String)
}

/// Result of a ``Conduit/pull()`` call (implemented in AT-02).
public enum PullResult: Sendable, Equatable {
    /// The pull succeeded; `commitsPulled` counts the commits received.
    case success(commitsPulled: Int)
    /// The local branch was already up to date; nothing was received.
    case upToDate
    /// No `origin` remote is configured on this repository.
    case noRemote
    /// A merge conflict was detected; the merge was aborted automatically.
    ///
    /// The vault directory is left in the same state as before the pull.
    /// Surfaces can use `conflicts` to offer a resolution UX.
    case abortedConflict(conflicts: [ConflictedFile])
}

/// Snapshot of a vault repository's working-tree and branch state.
public struct StatusResult: Sendable, Equatable {
    /// `true` if any modified, deleted, or untracked files are present.
    public let dirty: Bool
    /// Absolute URLs of files present in the working tree but not yet tracked.
    public let untrackedFiles: [URL]
    /// Absolute URLs of tracked files with unstaged or staged modifications.
    public let modifiedFiles: [URL]
    /// Absolute URLs of tracked files that have been deleted from the working tree.
    public let deletedFiles: [URL]
    /// Number of local commits not yet on the upstream branch.
    public let ahead: Int
    /// Number of upstream commits not yet in the local branch.
    public let behind: Int
    /// `true` if an upstream tracking branch (`branch.oob`) is configured.
    public let hasRemote: Bool

    /// Memberwise initializer.
    public init(
        dirty: Bool,
        untrackedFiles: [URL],
        modifiedFiles: [URL],
        deletedFiles: [URL],
        ahead: Int,
        behind: Int,
        hasRemote: Bool
    ) {
        self.dirty = dirty
        self.untrackedFiles = untrackedFiles
        self.modifiedFiles = modifiedFiles
        self.deletedFiles = deletedFiles
        self.ahead = ahead
        self.behind = behind
        self.hasRemote = hasRemote
    }
}

/// A file involved in a merge conflict, carrying both sides' git object SHAs.
///
/// Surfaces can retrieve each version with `git show <sha>` and decrypt with
/// the vault's age key to present a side-by-side resolution UX.
public struct ConflictedFile: Sendable, Equatable {
    /// Absolute path to the conflicting file in the vault directory.
    public let path: URL
    /// Git object hash for the local (ours) version of the file.
    public let localSHA: String
    /// Git object hash for the incoming (theirs) version of the file.
    public let remoteSHA: String

    /// Memberwise initializer.
    public init(path: URL, localSHA: String, remoteSHA: String) {
        self.path = path
        self.localSHA = localSHA
        self.remoteSHA = remoteSHA
    }
}
