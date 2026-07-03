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
    /// marker's parent directory, then standardizes the URL. Display/derivation
    /// only — write/delete consumers must use ``validatedTargetURL()``, which
    /// enforces containment.
    public var targetURL: URL {
        let raw = materializeTo ?? "./.env"
        return URL(fileURLWithPath: raw, relativeTo: markerURL.deletingLastPathComponent())
            .standardizedFileURL
    }

    /// ``targetURL`` with the ho-04.9 containment policy enforced.
    ///
    /// Markers sync via git — a crafted `materialize_to` in a cloned repo
    /// could otherwise direct `materialize` to write decrypted secrets to, or
    /// `clean` to DELETE, an arbitrary path. Policy: relative-only, and the
    /// standardized target must stay within the marker's own directory
    /// subtree. A legitimate cross-directory materialize is a deliberate
    /// future opt-in, not a default.
    ///
    /// - Returns: The standardized, contained target URL.
    /// - Throws: ``VaultError/markerMalformed(path:reason:)`` for absolute,
    ///   `~`-prefixed, or subtree-escaping targets.
    public func validatedTargetURL() throws -> URL {
        let raw = materializeTo ?? "./.env"
        guard !raw.hasPrefix("~") else {
            throw VaultError.markerMalformed(
                path: markerURL,
                reason: "materialize_to must not use ~ (got \"\(raw)\")"
            )
        }
        guard !raw.hasPrefix("/") else {
            throw VaultError.markerMalformed(
                path: markerURL,
                reason: "materialize_to must be a relative path (got absolute \"\(raw)\")"
            )
        }
        let base = markerURL.deletingLastPathComponent().standardizedFileURL
        let resolved = URL(fileURLWithPath: raw, relativeTo: base).standardizedFileURL
        // Lexical containment: after standardization (which resolves `..`),
        // the target must still sit under the marker's directory.
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard resolved.path.hasPrefix(basePath), resolved.path != base.path else {
            throw VaultError.markerMalformed(
                path: markerURL,
                reason: "materialize_to escapes the marker's directory (got \"\(raw)\")"
            )
        }
        return resolved
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
    /// The file's line for this owned key is malformed — the value is unreadable,
    /// so there is nothing to hash (ho-04.10). `materialize` rewrites the line
    /// in place once the drift gate is passed.
    case fileLineCorrupted(key: String)
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

/// A proposal produced by ``Materializer/ingest(directory:)``.
///
/// The Materializer suggests a scope identity, scope type, and per-key
/// classification; the surface layer collects user decisions and passes them
/// back through ``Materializer/acceptIngest(_:decisions:scopeID:scopeType:)``.
public struct ProposedScope: Sendable, Equatable {
    /// The project directory the proposal was built from.
    public let directory: URL

    /// Suggested scope ID.
    ///
    /// Derived from ``directory``'s last path component with sanitization and
    /// vault-side collision avoidance. The caller may override at accept time.
    public let suggestedScopeID: String

    /// Suggested ``ScopeType`` for the new scope.
    ///
    /// Defaults to `.projectDev` — ingest by nature means a project directory
    /// with a `.env`-family file. Callable can override at accept time.
    public let suggestedScopeType: ScopeType

    /// One entry per key detected in `.env`/`.env.local` with a real value.
    ///
    /// Ordered by first appearance; `.env.local` overrides `.env` for shared keys.
    public let detectedKeys: [DetectedKey]

    /// Keys that appeared only in `.env.example` (no value).
    ///
    /// Sorted alphabetically. Callers surface these as "you'll need values for these."
    public let suggestedKeysNeedingValues: [String]

    /// Parse warnings collected across all of the `.env`-family files read.
    public let parseWarnings: [ParseWarning]

    /// Memberwise initializer.
    public init(
        directory: URL,
        suggestedScopeID: String,
        suggestedScopeType: ScopeType,
        detectedKeys: [DetectedKey],
        suggestedKeysNeedingValues: [String],
        parseWarnings: [ParseWarning]
    ) {
        self.directory = directory
        self.suggestedScopeID = suggestedScopeID
        self.suggestedScopeType = suggestedScopeType
        self.detectedKeys = detectedKeys
        self.suggestedKeysNeedingValues = suggestedKeysNeedingValues
        self.parseWarnings = parseWarnings
    }
}

/// A single key/value pair detected during ingest.
public struct DetectedKey: Sendable, Equatable {
    /// The key name as read from the file.
    public let key: String

    /// The parsed value.
    public let value: String

    /// Which of `.env`/`.env.local` the key was read from (`.env.local` wins on collision).
    public let sourceFile: URL

    /// The shared entry ID with an exact case-sensitive name match, if any.
    ///
    /// The Materializer suggests `.linkToShared` for these; the surface can
    /// still choose otherwise.
    public let nameMatchedSharedID: String?

    /// Memberwise initializer.
    public init(key: String, value: String, sourceFile: URL, nameMatchedSharedID: String?) {
        self.key = key
        self.value = value
        self.sourceFile = sourceFile
        self.nameMatchedSharedID = nameMatchedSharedID
    }
}

/// One of five per-key routing choices `acceptIngest` accepts.
public enum KeyDecision: Sendable, Equatable {
    /// Encrypt the detected value into `vault/scopes/<scopeID>/<key>.age`.
    case importAsLocal(key: String)
    /// Link this key to an existing shared entry (no new encryption).
    case linkToShared(key: String, sharedID: String)
    /// Create a new shared entry with the detected value and link this scope to it.
    case moveToShared(key: String, newSharedID: String)
    /// Confirmed non-secret; write nothing.
    case leaveAlone(key: String)
    /// Deferred decision; write nothing this run.
    case skip(key: String)
}

/// Outcome of an `update` call.
public enum UpdateResult: Sendable, Equatable {
    /// One or more owned keys' vault values were rewritten to match the file.
    case updated(keysUpdated: [String], warnings: [ParseWarning])
    /// The file exists and parses, but no owned-key values differ from the vault.
    case noChanges(warnings: [ParseWarning])
    /// The marker points at a nonexistent target file.
    case fileMissing(path: URL)
}
