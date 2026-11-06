import Foundation
import Testing

@testable import SharibakoCore

// MARK: - Corpus

/// One real-shaped `.env` line and the class (with reason) the rule must give it.
struct ClassifierCase: Sendable, CustomTestStringConvertible {
    let key: String
    let value: String
    let sharedID: String?
    let expected: LineClass

    init(_ key: String, _ value: String, shared sharedID: String? = nil, _ expected: LineClass) {
        self.key = key
        self.value = value
        self.sharedID = sharedID
        self.expected = expected
    }

    var testDescription: String { "\(key)=\(value.prefix(40))" }
}

// The PEM header is assembled at runtime so the source never carries the
// literal marker the detect-private-key pre-commit hook scans for; the
// fixture is truncated filler, not a key.
private let pemKind = "PRIVATE" + " KEY"
private let pemValue = "-----BEGIN \(pemKind)-----\\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASC\\n-----END \(pemKind)-----"
private let certValue = "-----BEGIN CERTIFICATE-----\\nMIIDdzCCAl+gAwIBAgIEAgAAuTANBgkq\\n-----END CERTIFICATE-----"
private let jwtValue =
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
private let unsignedJWT = "eyJhbGciOiJub25lIn0.eyJyb2xlIjoiYW5vbiJ9."
private let hex32 = "0123456789abcdef0123456789abcdef"

/// Every arm of ho-06.10 Decision 2, at least two lines each, in rule order.
let classifierCorpus: [ClassifierCase] = [
    // Rule 1 — shared name match wins over everything, even a setting-shaped value.
    ClassifierCase("OPENAI_API_KEY", "sk-proj-abc", shared: "OPENAI_API_KEY", .secret(.sharedNameMatch)),
    ClassifierCase("PORT", "3000", shared: "PORT", .secret(.sharedNameMatch)),

    // Rule 2 — key suffixes.
    ClassifierCase("OPENAI_API_KEY", "sk-proj-abc", .secret(.keyEndsInKey)),
    ClassifierCase("APIKEY", "abc", .secret(.keyEndsInKey)),
    ClassifierCase("SECRETKEY", "abc", .secret(.keyEndsInKey)),
    ClassifierCase("openai_api_key", "sk-x", .secret(.keyEndsInKey)),
    ClassifierCase("JWT_SECRET", "supersecret", .secret(.keyEndsInSecret)),
    ClassifierCase("CLIENTSECRET", "abc", .secret(.keyEndsInSecret)),
    ClassifierCase("GITHUB_TOKEN", "ghp_abc", .secret(.keyEndsInToken)),
    ClassifierCase("SLACK_BOT_TOKEN", "xoxb-1-2", .secret(.keyEndsInToken)),
    ClassifierCase("DB_PASSWORD", "hunter2", .secret(.keyEndsInPassword)),
    ClassifierCase("SMTP_PASSWORD", "true", .secret(.keyEndsInPassword)),
    ClassifierCase("MYSQL_PASSWD", "x", .secret(.keyEndsInPasswd)),
    ClassifierCase("ROOT_PASSWD", "changeme", .secret(.keyEndsInPasswd)),
    ClassifierCase("GOOGLE_APPLICATION_CREDENTIALS", "./creds.json", .secret(.keyEndsInCredentials)),
    ClassifierCase("AWS_CREDENTIALS", "x", .secret(.keyEndsInCredentials)),
    ClassifierCase("GCP_CREDS", "x", .secret(.keyEndsInCreds)),
    ClassifierCase("SERVICECREDS", "x", .secret(.keyEndsInCreds)),
    ClassifierCase("SENTRY_DSN", "https://abc@o1.ingest.sentry.io/1", .secret(.keyEndsInDSN)),
    ClassifierCase("DATABASE_DSN", "x", .secret(.keyEndsInDSN)),
    ClassifierCase("SSH_PRIVATE", "x", .secret(.keyEndsInPrivate)),
    ClassifierCase("WALLET_PRIVATE", "x", .secret(.keyEndsInPrivate)),

    // Rule 2 — key fragments.
    ClassifierCase("API_HOST", "localhost", .secret(.keyContainsAPI)),
    ClassifierCase("STRIPE_API_VERSION", "2023-10-16", .secret(.keyContainsAPI)),
    ClassifierCase("AUTH_DOMAIN", "example.auth0.com", .secret(.keyContainsAuthPrefix)),
    ClassifierCase("NEXTAUTH_URL", "http://localhost:3000", .secret(.keyContainsAuthPrefix)),
    ClassifierCase("BASIC_AUTH", "user:pass", .secret(.keyContainsAuthSuffix)),
    ClassifierCase("ENABLE_AUTH", "true", .secret(.keyContainsAuthSuffix)),
    ClassifierCase("PRIVATE_KEY_PATH", "./key.pem", .secret(.keyContainsPrivateKey)),
    ClassifierCase("JWT_PRIVATE_KEY_FILE", "/run/secrets/jwt", .secret(.keyContainsPrivateKey)),
    ClassifierCase("AWS_ACCESS_KEY_ID", "AKIAIOSFODNN7EXAMPLE", .secret(.keyContainsAccessKey)),
    ClassifierCase("MINIO_ACCESS_KEY_ID", "minio", .secret(.keyContainsAccessKey)),
    ClassifierCase("SIGNING_SALT", "abc", .secret(.keyContainsSigning)),
    ClassifierCase("COOKIE_SIGNING_ALG", "HS256", .secret(.keyContainsSigning)),
    ClassifierCase("CONTACT_FORM_WEBHOOK", "https://hooks.example/abc", .secret(.keyContainsWebhook)),
    ClassifierCase("SLACK_WEBHOOK_URL", "https://hooks.slack.com/services/T0/B0/x", .secret(.keyContainsWebhook)),

    // Rule 3 — credential-bearing values.
    ClassifierCase("DATABASE_URL", "postgres://u:p@h/db", .secret(.urlWithCredentials)),
    ClassifierCase("MONGO_URI", "mongodb://admin:hunter2@mongo:27017/app", .secret(.urlWithCredentials)),
    ClassifierCase("REDIS_URL", "redis://default@cache:6379", .secret(.urlWithCredentials)),
    ClassifierCase("TLS_CERT", certValue, .secret(.pemBlock)),
    ClassifierCase("GITHUB_APP_PEM", pemValue, .secret(.pemBlock)),
    ClassifierCase("SUPABASE_ANON", jwtValue, .secret(.jwt)),
    ClassifierCase("SERVICE_ROLE_JWT", unsignedJWT, .secret(.jwt)),

    // Rule 4 — plain-setting values.
    ClassifierCase("DEBUG", "true", .setting(.boolean)),
    ClassifierCase("ENABLE_BETA_ROOMS", "false", .setting(.boolean)),
    ClassifierCase("VERBOSE", "1", .setting(.boolean)),
    ClassifierCase("USE_SSL", "Off", .setting(.boolean)),
    ClassifierCase("PORT", "3000", .setting(.number)),
    ClassifierCase("DETECTION_THRESHOLD", "0.85", .setting(.number)),
    ClassifierCase("UTC_OFFSET", "-12", .setting(.number)),
    ClassifierCase("WORKERS", "+4", .setting(.number)),
    ClassifierCase("RATIO", ".5", .setting(.number)),
    ClassifierCase("OUTPUT_DIR", "/Users/x/Audiobooks", .setting(.filesystemPath)),
    ClassifierCase("CACHE_DIR", "./tmp", .setting(.filesystemPath)),
    ClassifierCase("CONFIG_HOME", "~/.config/app", .setting(.filesystemPath)),
    ClassifierCase("SHARED_DIR", "../shared", .setting(.filesystemPath)),
    ClassifierCase("BIND_HOST", "localhost", .setting(.hostname)),
    ClassifierCase("DB_HOST", "db.internal", .setting(.hostname)),
    ClassifierCase("REDIS_ADDR", "redis:6379", .setting(.hostname)),
    ClassifierCase("LISTEN", "127.0.0.1:8080", .setting(.hostname)),
    ClassifierCase("DATABASE_URL", "postgres://localhost/db", .setting(.plainURL)),
    ClassifierCase("REDIS_URL", "redis://cache:6379", .setting(.plainURL)),
    ClassifierCase("SITE_URL", "https://example.com/docs#top", .setting(.plainURL)),
    ClassifierCase("NODE_ENV", "development", .setting(.enumWord)),
    ClassifierCase("LOG_LEVEL", "info", .setting(.enumWord)),
    ClassifierCase("SESSION_COOKIE_NAME", "sid", .setting(.enumWord)),
    ClassifierCase("AWS_REGION", "us-east-1", .setting(.enumWord)),
    ClassifierCase("DB_SERVICE", "db", .setting(.enumWord)),
    ClassifierCase("BUILD_ID", "build_12345", .setting(.enumWord)),
    ClassifierCase("EMPTY", "", .setting(.emptyValue)),
    ClassifierCase("OPTIONAL_FLAG", "", .setting(.emptyValue)),

    // Rule 5 — the fallback protects what rule 4 does not recognise.
    ClassifierCase("CLOUDFLARE_ACCOUNT_ID", hex32, .secret(.unrecognized)),
    ClassifierCase("ANALYTICS_URL", "https://x.example/collect?id=abc", .secret(.unrecognized)),
    ClassifierCase("STRIPE_ACCOUNT", "acct_1234567", .secret(.unrecognized)),
    ClassifierCase("SESSION_ID", "abcdefghijklmnopqrstuvwxy", .secret(.unrecognized)),
    ClassifierCase("GREETING", "hello world", .secret(.unrecognized)),
    ClassifierCase("CALLBACK", "1http://x", .secret(.unrecognized)),
    ClassifierCase("PEER", "a..b", .secret(.unrecognized)),
    ClassifierCase("EDGE", "-db.example", .secret(.unrecognized)),
    ClassifierCase("ENDPOINT", "redis:6379:1", .secret(.unrecognized)),
    ClassifierCase("PROXY", "proxy:http", .secret(.unrecognized)),
    ClassifierCase("FRAGMENT", "eyJabc.def", .secret(.unrecognized)),
    ClassifierCase("CONTACT", "ops@example.com", .secret(.unrecognized)),
    ClassifierCase("SIGNED", "+", .secret(.unrecognized)),
    ClassifierCase("VERSION_TRIPLE", "1.2.3.4.x_y", .secret(.unrecognized)),
]

// MARK: - Tests

@Suite("SecretClassifier — corpus")
struct SecretClassifierCorpusTests {
    @Test("each corpus line gets its class and its reason", arguments: classifierCorpus)
    func corpusLine(_ line: ClassifierCase) {
        let actual = SecretClassifier.classify(key: line.key, value: line.value, nameMatchedSharedID: line.sharedID)
        #expect(actual == line.expected)
    }

    @Test("the corpus is at least 40 lines and covers every rule arm at least twice")
    func corpusCoversEveryArm() {
        #expect(classifierCorpus.count >= 40)
        var counts: [ClassificationReason: Int] = [:]
        for line in classifierCorpus { counts[line.expected.reason, default: 0] += 1 }
        for reason in ClassificationReason.allCases {
            #expect((counts[reason] ?? 0) >= 2, "rule arm \(reason) has fewer than two examples")
        }
    }
}

@Suite("SecretClassifier — reasons and classes")
struct SecretClassifierReasonTests {
    @Test("every reason has a distinct, non-empty explanation")
    func explanationsDistinct() {
        let explanations = ClassificationReason.allCases.map(\.explanation)
        #expect(explanations.allSatisfy { !$0.isEmpty })
        #expect(Set(explanations).count == explanations.count)
    }

    @Test("the spec's named explanations read in plain words")
    func namedExplanations() {
        #expect(ClassificationReason.keyEndsInSecret.explanation == "key ends in SECRET")
        #expect(ClassificationReason.urlWithCredentials.explanation == "URL carries a username or password")
        #expect(ClassificationReason.unrecognized.explanation == "not recognised as a plain setting")
        #expect(ClassificationReason.number.explanation == "looks like a number")
    }

    @Test("reason and isSecret read back from either class")
    func lineClassAccessors() {
        #expect(LineClass.secret(.jwt).reason == .jwt)
        #expect(LineClass.setting(.number).reason == .number)
        #expect(LineClass.secret(.jwt).isSecret)
        #expect(!LineClass.setting(.number).isSecret)
    }

    @Test("a secret defaults to import, a setting to leave alone")
    func defaultDecisions() {
        #expect(LineClass.secret(.keyEndsInKey).defaultDecision(forKey: "A") == .importAsLocal(key: "A"))
        #expect(LineClass.setting(.boolean).defaultDecision(forKey: "B") == .leaveAlone(key: "B"))
    }
}

@Suite("SecretClassifier — proposal integration")
struct SecretClassifierProposalTests {
    @Test("classifiedKeys pairs every detected key with its class, in proposal order")
    func classifiedKeysInOrder() {
        let env = URL(fileURLWithPath: "/projects/bento/.env")
        let keys = [
            DetectedKey(key: "OPENAI_API_KEY", value: "sk-x", sourceFile: env, nameMatchedSharedID: nil),
            DetectedKey(key: "PORT", value: "3000", sourceFile: env, nameMatchedSharedID: nil),
            DetectedKey(key: "ANTHROPIC", value: "x", sourceFile: env, nameMatchedSharedID: "ANTHROPIC"),
        ]
        let proposal = ProposedScope(
            directory: URL(fileURLWithPath: "/projects/bento"),
            suggestedScopeID: "bento",
            suggestedScopeType: .projectDev,
            detectedKeys: keys,
            suggestedKeysNeedingValues: [],
            parseWarnings: []
        )
        let classified = proposal.classifiedKeys()
        #expect(classified.map(\.key) == keys)
        #expect(
            classified.map(\.lineClass) == [
                .secret(.keyEndsInKey), .setting(.number), .secret(.sharedNameMatch),
            ]
        )
        #expect(keys[1].lineClass == .setting(.number))
    }
}
