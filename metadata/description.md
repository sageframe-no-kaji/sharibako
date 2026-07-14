# Sharibako — description

A local, age-encrypted, git-backed vault for API keys and environment variables, organized the way work actually happens — by project and by machine.

Secrets scatter — across the system keychain, .env files, shell config, and old chat transcripts — and the scatter is the problem Sharibako (舎利箱, a reliquary box) solves by giving them a storage shape that matches how work is actually organized. It holds API keys, environment variables, and service credentials as age-encrypted files in a git-backed vault, edited through a native Mac app or a cross-platform CLI. Two output verbs address different deployment contexts: `sharibako materialize` writes decrypted .env files for consumers that cannot be wrapped, and `sharibako run -- <cmd>` injects secrets into a child process's environment without ever touching disk. Secrets can be linked across projects, so rotating one propagates everywhere it is used. It is the secrets-governance layer of the Kṣetra-Ops suite, alongside Pālana and Forteller — power and responsibility over your own credentials, held in the open on your own machine rather than behind another black box.

Swift 6 for macOS 14+ (Apple Silicon), using swift-argument-parser, swift-log, and Yams, built as a core library, a CLI binary, and a SwiftUI app; open-source under GPL-3.0. In active development toward v1.
