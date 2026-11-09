import Foundation

/// Why ``SecretClassifier`` classed a `.env` line the way it did.
///
/// One case per arm of the rule (ho-06.10 Decision 2), so a surface can show
/// the user *which* arm fired — the review screen's tooltip, the CLI's
/// parenthesised note — and the user can judge whether to flip the line. The
/// raw value is the case name, stable for machine output.
public enum ClassificationReason: String, Sendable, CaseIterable {
    // Rule 1 — shared-entry name match.

    /// The key's name matches a shared entry already in the vault.
    case sharedNameMatch

    // Rule 2 — key shape, suffixes (checked in this order).

    /// The uppercased key ends in `KEY`.
    case keyEndsInKey
    /// The uppercased key ends in `SECRET`.
    case keyEndsInSecret
    /// The uppercased key ends in `TOKEN`.
    case keyEndsInToken
    /// The uppercased key ends in `PASSWORD`.
    case keyEndsInPassword
    /// The uppercased key ends in `PASSWD`.
    case keyEndsInPasswd
    /// The uppercased key ends in `CREDENTIALS`.
    case keyEndsInCredentials
    /// The uppercased key ends in `CREDS`.
    case keyEndsInCreds
    /// The uppercased key ends in `DSN`.
    case keyEndsInDSN
    /// The uppercased key ends in `PRIVATE`.
    case keyEndsInPrivate

    // Rule 2 — key shape, fragments (checked in this order, after the suffixes).

    /// The uppercased key contains `API_`.
    case keyContainsAPI
    /// The uppercased key contains `AUTH_`.
    case keyContainsAuthPrefix
    /// The uppercased key contains `_AUTH`.
    case keyContainsAuthSuffix
    /// The uppercased key contains `PRIVATE_KEY`.
    case keyContainsPrivateKey
    /// The uppercased key contains `ACCESS_KEY`.
    case keyContainsAccessKey
    /// The uppercased key contains `SIGNING`.
    case keyContainsSigning
    /// The uppercased key contains `WEBHOOK`.
    case keyContainsWebhook

    // Rule 3 — credential-bearing value shapes.

    /// The value is a URL whose authority carries user info (`scheme://user:pass@host`).
    case urlWithCredentials
    /// The value contains a PEM block (`-----BEGIN`).
    case pemBlock
    /// The value is a JSON Web Token (three base64url segments, header `eyJ…`).
    case jwt

    // Rule 4 — plain-setting value shapes.

    /// The value is a boolean word or digit (`true/false/yes/no/on/off/0/1`).
    case boolean
    /// The value is an integer or decimal with an optional sign.
    case number
    /// The value is a filesystem path (`/`, `~`, `./`, `../` prefix) with no `@`.
    case filesystemPath
    /// The value is a hostname or `host:port`.
    case hostname
    /// The value is a URL with no user info and no query string.
    case plainURL
    /// The value is a short word of letters, digits, `-` and `_`.
    case enumWord
    /// The value is empty.
    case emptyValue

    // Rule 5 — the fallback.

    /// No setting shape matched, so the line is protected by default.
    case unrecognized

    /// The reason in plain words, for a tooltip or a parenthesised CLI note.
    public var explanation: String {
        switch self {
        case .sharedNameMatch: "key matches a shared entry in the vault"
        case .keyEndsInKey: "key ends in KEY"
        case .keyEndsInSecret: "key ends in SECRET"
        case .keyEndsInToken: "key ends in TOKEN"
        case .keyEndsInPassword: "key ends in PASSWORD"
        case .keyEndsInPasswd: "key ends in PASSWD"
        case .keyEndsInCredentials: "key ends in CREDENTIALS"
        case .keyEndsInCreds: "key ends in CREDS"
        case .keyEndsInDSN: "key ends in DSN"
        case .keyEndsInPrivate: "key ends in PRIVATE"
        case .keyContainsAPI: "key contains API_"
        case .keyContainsAuthPrefix: "key contains AUTH_"
        case .keyContainsAuthSuffix: "key contains _AUTH"
        case .keyContainsPrivateKey: "key contains PRIVATE_KEY"
        case .keyContainsAccessKey: "key contains ACCESS_KEY"
        case .keyContainsSigning: "key contains SIGNING"
        case .keyContainsWebhook: "key contains WEBHOOK"
        case .urlWithCredentials: "URL carries a username or password"
        case .pemBlock: "looks like a PEM key or certificate"
        case .jwt: "looks like a JSON Web Token"
        case .boolean: "looks like an on/off switch"
        case .number: "looks like a number"
        case .filesystemPath: "looks like a file path"
        case .hostname: "looks like a hostname"
        case .plainURL: "URL with no login and no query string"
        case .enumWord: "looks like a plain word"
        case .emptyValue: "value is empty"
        case .unrecognized: "not recognised as a plain setting"
        }
    }
}

/// The class ``SecretClassifier`` gives a `.env` line: protect it, or leave it alone.
///
/// A class is a *default*, never a decision. Both surfaces show it and let
/// the user flip any line (ho-06.10 Decision 3).
public enum LineClass: Sendable, Hashable {
    /// The line should be protected — encrypted into the vault.
    case secret(ClassificationReason)
    /// The line is a plain setting — left in the `.env`, untouched.
    case setting(ClassificationReason)

    /// The rule arm that produced this class.
    public var reason: ClassificationReason {
        switch self {
        case .secret(let reason), .setting(let reason): reason
        }
    }

    /// `true` for ``secret(_:)``.
    public var isSecret: Bool {
        if case .secret = self { return true }
        return false
    }

    /// The ingest decision this class defaults to.
    ///
    /// A secret is imported as scope-local and a setting is left alone. The
    /// mapping lives here so the CLI and the Workshop cannot drift apart on
    /// what "the default" means; linking a shared-name match stays a choice
    /// the user makes on the review screen.
    ///
    /// - Parameter key: The key the decision is for.
    /// - Returns: `.importAsLocal(key:)` for a secret, `.leaveAlone(key:)` for a setting.
    public func defaultDecision(forKey key: String) -> KeyDecision {
        isSecret ? .importAsLocal(key: key) : .leaveAlone(key: key)
    }
}

/// Classes each `.env` line as a secret or a setting, to set the defaults on
/// the review screen (ho-06.10 Decisions 1–2).
///
/// Pure and deterministic: no I/O, no vault access, Foundation only. The rule
/// runs in this order and the first arm that fires wins:
///
/// 1. **Shared name match → secret.** The key name-matches a shared entry
///    already in the vault (``ClassificationReason/sharedNameMatch``); the
///    shared ID on the ``DetectedKey`` is the suggested link.
/// 2. **Key shape → secret.** The uppercased key ends in `KEY`, `SECRET`,
///    `TOKEN`, `PASSWORD`, `PASSWD`, `CREDENTIALS`, `CREDS`, `DSN`, or
///    `PRIVATE` (an underscore before the suffix is optional: `APIKEY`,
///    `API_KEY`, and `SECRETKEY` all match), or contains `API_`, `AUTH_`,
///    `_AUTH`, `PRIVATE_KEY`, `ACCESS_KEY`, `SIGNING`, or `WEBHOOK`. Suffixes
///    are checked before fragments, each list in the order written here.
/// 3. **Credential-bearing value → secret.** A URL whose authority carries
///    user info (`scheme://user:pass@…`); a PEM block (`-----BEGIN`); a JWT
///    (three `.`-separated base64url segments whose header starts `eyJ`, the
///    encoding of `{"`).
/// 4. **Plain-setting value → setting.** A boolean
///    (`true/false/yes/no/on/off/0/1`, any case); a number (integer or
///    decimal, optional sign); a filesystem path (`/`, `~`, `./`, `../`
///    prefix) with no `@`; a hostname or `host:port` (`[a-z0-9.-]+(:\d+)?`);
///    a URL with a scheme, no user info, and no `?`; an enum-looking word (at
///    most 24 characters of `[A-Za-z0-9_-]` with no run of six or more
///    digits); an empty value.
/// 5. **Otherwise → secret** (``ClassificationReason/unrecognized``). A
///    wrong "setting" leaves a secret in plain text; a wrong "secret" only
///    puts a config value in the vault. So what the rule does not recognise
///    as a plain setting is protected, and the user flips it if it isn't.
///
/// There is deliberately no entropy threshold: rule 4's shapes cover what
/// settings look like, and the fallback protects the rest.
///
/// A single-label hostname (`db`, `cache`) is indistinguishable from a word,
/// so the hostname arm requires a dot, a port, or `localhost`; bare labels
/// fall to the enum-word arm, still a setting. Without that, a long
/// lowercase hex token would read as a hostname and be left in plain text.
public enum SecretClassifier {
    /// Classes one `.env` line.
    ///
    /// - Parameters:
    ///   - key: The key as read from the file (any case; matched uppercased).
    ///   - value: The parsed value (quotes already stripped by the parser).
    ///   - nameMatchedSharedID: The shared entry the key name-matches, if any.
    /// - Returns: The line's class and the rule arm that produced it.
    public static func classify(key: String, value: String, nameMatchedSharedID: String?) -> LineClass {
        if nameMatchedSharedID != nil { return .secret(.sharedNameMatch) }
        if let reason = keyShapeReason(key) { return .secret(reason) }
        if let reason = secretValueReason(value) { return .secret(reason) }
        if let reason = settingValueReason(value) { return .setting(reason) }
        return .secret(.unrecognized)
    }

    // MARK: - Rule 2: key shape

    private static let keySuffixes: [(term: String, reason: ClassificationReason)] = [
        ("KEY", .keyEndsInKey),
        ("SECRET", .keyEndsInSecret),
        ("TOKEN", .keyEndsInToken),
        ("PASSWORD", .keyEndsInPassword),
        ("PASSWD", .keyEndsInPasswd),
        ("CREDENTIALS", .keyEndsInCredentials),
        ("CREDS", .keyEndsInCreds),
        ("DSN", .keyEndsInDSN),
        ("PRIVATE", .keyEndsInPrivate),
    ]

    private static let keyFragments: [(term: String, reason: ClassificationReason)] = [
        ("API_", .keyContainsAPI),
        ("AUTH_", .keyContainsAuthPrefix),
        ("_AUTH", .keyContainsAuthSuffix),
        ("PRIVATE_KEY", .keyContainsPrivateKey),
        ("ACCESS_KEY", .keyContainsAccessKey),
        ("SIGNING", .keyContainsSigning),
        ("WEBHOOK", .keyContainsWebhook),
    ]

    /// Rule 2: key shape.
    ///
    /// A bare suffix match already makes the `_` optional: `API_KEY` and
    /// `APIKEY` both end in `KEY`.
    private static func keyShapeReason(_ key: String) -> ClassificationReason? {
        let upper = key.uppercased()
        if let hit = keySuffixes.first(where: { upper.hasSuffix($0.term) }) { return hit.reason }
        return keyFragments.first { upper.contains($0.term) }?.reason
    }

    // MARK: - Rule 3: credential-bearing values

    private static func secretValueReason(_ value: String) -> ClassificationReason? {
        if let authority = urlAuthority(value), authority.contains("@") { return .urlWithCredentials }
        if value.contains("-----BEGIN") { return .pemBlock }
        if isJWT(value) { return .jwt }
        return nil
    }

    /// The authority of `scheme://authority/…`, or `nil` when `value` has no
    /// valid scheme followed by `://`.
    private static func urlAuthority(_ value: String) -> Substring? {
        guard let separator = value.range(of: "://") else { return nil }
        let scheme = value[..<separator.lowerBound]
        guard let first = scheme.first, first.isASCII, first.isLetter,
            scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) })
        else { return nil }
        let rest = value[separator.upperBound...]
        let end = rest.firstIndex { "/?#".contains($0) } ?? rest.endIndex
        return rest[..<end]
    }

    private static func isJWT(_ value: String) -> Bool {
        let segments = value.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, segments[0].hasPrefix("eyJ"), !segments[1].isEmpty else { return false }
        return segments.allSatisfy { $0.allSatisfy(isBase64URL) }
    }

    private static func isBase64URL(_ char: Character) -> Bool {
        char.isASCII && (char.isLetter || char.isNumber || char == "-" || char == "_")
    }

    // MARK: - Rule 4: plain-setting values

    private static let booleanWords: Set<String> = ["true", "false", "yes", "no", "on", "off", "0", "1"]

    private static func settingValueReason(_ value: String) -> ClassificationReason? {
        if booleanWords.contains(value.lowercased()) { return .boolean }
        if isNumber(value) { return .number }
        if isFilesystemPath(value) { return .filesystemPath }
        if isHostname(value) { return .hostname }
        if urlAuthority(value) != nil, !value.contains("?") { return .plainURL }
        if isEnumWord(value) { return .enumWord }
        if value.isEmpty { return .emptyValue }
        return nil
    }

    private static func isDigits<S: StringProtocol>(_ text: S) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Integer or decimal with an optional sign: `3000`, `-1`, `+2.5`, `0.85`, `.5`.
    private static func isNumber(_ value: String) -> Bool {
        var body = Substring(value)
        if let sign = body.first, sign == "+" || sign == "-" { body = body.dropFirst() }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        switch parts.count {
        case 1: return isDigits(parts[0])
        case 2: return (parts[0].isEmpty || isDigits(parts[0])) && isDigits(parts[1])
        default: return false
        }
    }

    private static func isFilesystemPath(_ value: String) -> Bool {
        let prefixes = ["/", "~", "./", "../"]
        return prefixes.contains { value.hasPrefix($0) } && !value.contains("@")
    }

    /// `[a-z0-9.-]+(:\d+)?` with well-formed labels, and — so a lone word or
    /// a long lowercase token does not pass as a host — a dot, a port, or
    /// exactly `localhost`.
    private static func isHostname(_ value: String) -> Bool {
        let pieces = value.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count <= 2 else { return false }
        let host = pieces[0]
        let hasPort = pieces.count == 2
        if hasPort, !isDigits(pieces[1]) { return false }
        let allowed = host.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "." || $0 == "-") }
        guard allowed, !host.isEmpty else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let wellFormed = labels.allSatisfy { !$0.isEmpty && $0.first != "-" && $0.last != "-" }
        return wellFormed && (hasPort || labels.count > 1 || host == "localhost")
    }

    /// At most 24 characters of `[A-Za-z0-9_-]`, no run of six or more digits
    /// (a run that long is an ID or a code, not a mode name).
    private static func isEnumWord(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 24 else { return false }
        var digitRun = 0
        for char in value {
            guard char.isASCII, char.isLetter || char.isNumber || char == "-" || char == "_" else { return false }
            digitRun = char.isNumber ? digitRun + 1 : 0
            if digitRun >= 6 { return false }
        }
        return true
    }
}

extension ProposedScope {
    /// Every detected key paired with its ``LineClass``, in proposal order.
    ///
    /// The review surfaces render this list: every line, settings included,
    /// each with the default its class implies.
    public func classifiedKeys() -> [(key: DetectedKey, lineClass: LineClass)] {
        detectedKeys.map { ($0, $0.lineClass) }
    }
}

extension DetectedKey {
    /// This key's class under ``SecretClassifier``.
    ///
    /// Computed from the stored fields, so `DetectedKey` itself is unchanged.
    public var lineClass: LineClass {
        SecretClassifier.classify(key: key, value: value, nameMatchedSharedID: nameMatchedSharedID)
    }
}
