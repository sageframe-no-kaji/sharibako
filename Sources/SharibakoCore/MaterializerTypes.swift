import Foundation

/// A `.sharibako` marker file, decoded from YAML plus the path it was read from.
///
/// Markers pin a project directory to a scope in the vault and name the target file
/// `materialize` should write to. Both fields are declared in the on-disk YAML;
/// ``markerURL`` records where that YAML lives so ``targetURL`` can resolve the
/// (relative) ``materializeTo`` against the marker's own directory.
///
/// Only ``scope`` and ``materializeTo`` participate in `Codable`. When decoding from
/// YAML, ``markerURL`` receives a placeholder; the marker loader replaces it via
/// ``withMarkerURL(_:)`` before returning the value to callers.
public struct ScopeMarker: Sendable, Equatable, Codable {
    /// Vault scope identifier this marker binds to.
    public let scope: String

    /// Relative path (from the marker's directory) to the file `materialize` writes.
    ///
    /// `nil` means the default of `./.env`.
    public let materializeTo: String?

    /// Absolute URL of the `.sharibako` file itself.
    ///
    /// Not encoded to YAML — set by the loader after decoding.
    public let markerURL: URL

    /// Memberwise initializer.
    public init(scope: String, materializeTo: String?, markerURL: URL) {
        self.scope = scope
        self.materializeTo = materializeTo
        self.markerURL = markerURL
    }

    /// YAML field names — `materialize_to` uses snake_case in the file.
    private enum CodingKeys: String, CodingKey {
        case scope
        case materializeTo = "materialize_to"
    }

    /// Decodes a marker from YAML, leaving ``markerURL`` as a placeholder to be
    /// replaced by the loader via ``withMarkerURL(_:)``.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.scope = try container.decode(String.self, forKey: .scope)
        self.materializeTo = try container.decodeIfPresent(String.self, forKey: .materializeTo)
        self.markerURL = URL(fileURLWithPath: "/")
    }

    /// Encodes only ``scope`` and ``materializeTo`` — ``markerURL`` is a runtime property.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scope, forKey: .scope)
        try container.encodeIfPresent(materializeTo, forKey: .materializeTo)
    }

    /// The absolute path `materialize`/`clean`/`heal` operate on.
    ///
    /// Resolves ``materializeTo`` (defaulting to `./.env` when nil) against the
    /// marker's parent directory, then standardizes the URL.
    public var targetURL: URL {
        let raw = materializeTo ?? "./.env"
        return URL(fileURLWithPath: raw, relativeTo: markerURL.deletingLastPathComponent())
            .standardizedFileURL
    }

    /// Returns a copy of this marker with ``markerURL`` replaced.
    ///
    /// Used by the loader after decoding YAML to attach the actual on-disk path.
    public func withMarkerURL(_ url: URL) -> Self {
        Self(scope: scope, materializeTo: materializeTo, markerURL: url)
    }
}

/// Where a scope sits from the point of view of a machine running `sharibako status`.
public enum ScopeState: Sendable, Equatable {
    /// Scope exists in the vault and a marker for it was found in the configured scan roots.
    case liveHere(markerURL: URL, targetURL: URL)
    /// Scope exists in the vault but no marker for it appears in the configured scan roots.
    case liveElsewhere
    /// A marker references a scope the vault doesn't have.
    case orphaned(markerURL: URL, reason: String)
}

/// Outcome of a `materialize` call.
public enum MaterializeResult: Sendable, Equatable {
    /// The target file was written; `keysWritten` lists every owned key present in the output.
    case wrote(path: URL, keysWritten: [String])
    /// The target file already matched what `materialize` would have written.
    case unchanged(path: URL)
    /// One or more owned keys have drifted and `overwriteDrift` was `false`; nothing written.
    case diffPending(diff: MaterializeDiff)
}

/// Describes the drift `materialize` refused to overwrite.
public struct MaterializeDiff: Sendable, Equatable {
    /// The scope this diff belongs to.
    public let scopeID: String

    /// Absolute path of the target file.
    public let path: URL

    /// Owned keys whose file value differs from the vault value.
    ///
    /// Sorted alphabetically.
    public let ownedKeysDiffering: [String]

    /// Owned keys with no matching `KEY=` line in the file.
    ///
    /// Sorted alphabetically.
    public let ownedKeysMissingFromFile: [String]

    /// Memberwise initializer.
    public init(
        scopeID: String,
        path: URL,
        ownedKeysDiffering: [String],
        ownedKeysMissingFromFile: [String]
    ) {
        self.scopeID = scopeID
        self.path = path
        self.ownedKeysDiffering = ownedKeysDiffering
        self.ownedKeysMissingFromFile = ownedKeysMissingFromFile
    }
}

/// Result of a `heal` call — per-key drift for the scope's owned keys.
///
/// Non-owned lines in the target file are invisible to `heal` and never appear here.
public struct DriftReport: Sendable, Equatable {
    /// Scope this report covers.
    public let scopeID: String

    /// Absolute path of the target file that was inspected.
    public let path: URL

    /// One entry per owned key.
    ///
    /// Sorted by key.
    public let owned: [KeyDrift]

    /// Parse warnings collected while reading the target file.
    public let parseWarnings: [ParseWarning]

    /// Memberwise initializer.
    public init(scopeID: String, path: URL, owned: [KeyDrift], parseWarnings: [ParseWarning]) {
        self.scopeID = scopeID
        self.path = path
        self.owned = owned
        self.parseWarnings = parseWarnings
    }
}

/// Drift state for a single owned key.
public enum KeyDrift: Sendable, Equatable {
    /// Vault value and file value agree byte-for-byte.
    case match(key: String)
    /// Vault has the key but the target file does not.
    case fileMissing(key: String)
    /// Both sides have the key but their values differ; SHA-256 hex digests of each side.
    case fileValueDiffers(key: String, vaultSha256: String, fileSha256: String)
}

/// Outcome of a `clean` call.
public enum CleanResult: Sendable, Equatable {
    /// The target file was rewritten (or deleted) with owned lines removed.
    ///
    /// `fileStillExists` is `false` when the file was deleted because nothing but
    /// blanks and comments remained.
    case cleaned(path: URL, keysRemoved: [String], fileStillExists: Bool)
    /// No target file was present to clean.
    case fileMissing(path: URL)
}

/// A non-fatal issue the `.env` parser flagged while reading a file.
public struct ParseWarning: Sendable, Equatable {
    /// The file being parsed.
    public let file: URL

    /// 1-indexed line number in the file.
    public let lineNumber: Int

    /// The raw line text as it appeared in the file.
    public let text: String

    /// Human-readable reason.
    public let reason: String

    /// Memberwise initializer.
    public init(file: URL, lineNumber: Int, text: String, reason: String) {
        self.file = file
        self.lineNumber = lineNumber
        self.text = text
        self.reason = reason
    }
}
