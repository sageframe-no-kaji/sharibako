import ArgumentParser
import SharibakoCore

/// Root entry point for the `sharibako` CLI.
@available(macOS 10.15, *)
@main
struct SharibakoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sharibako",
        abstract: "A local encrypted secrets vault, backed by age and git.",
        discussion: """
            Sharibako is a local, git-backed vault for API keys and environment \
            variables. Each secret is an age-encrypted file on disk; the vault is \
            a plain directory you control, and the filesystem itself is the \
            schema - no sidecar database. Secrets are organized by SCOPE (a \
            project, a deployed service, or a machine), and a value used by more \
            than one \
            scope can live once in the SHARED pool with each scope LINKing to it, \
            so a single rotation propagates everywhere.

            Two output verbs move secrets out of the vault, with different exposure \
            profiles. 'materialize' writes a plaintext .env file at a scope's \
            target path - use it only for consumers that cannot be wrapped \
            (docker-compose services, systemd units, cron jobs). 'run' decrypts \
            into memory and exec-replaces into your command with the values in its \
            environment, leaving nothing on disk - the right verb for anything you \
            launch interactively (npm run dev, python app.py, cargo run). 'update' \
            closes the loop the other way, reading hand-edits back out of .env into \
            the vault. See the materialize and run pages, and SECURITY.md, for \
            the exposure trade-off.

            RESOLUTION ORDER

            The vault directory is resolved from, in order: the --vault flag, the \
            SHARIBAKO_VAULT environment variable, then the default \
            ~/.sharibako/vault. If none of these names an existing directory the \
            command fails; run 'sharibako key generate' to create the vault and \
            age key on first use.

            The age identity key is resolved from, in order: the --age-key flag, \
            the SHARIBAKO_AGE_KEY environment variable, then - on macOS - the \
            Keychain (unlocked with Touch ID per operation), or - on Linux - the \
            plaintext file ~/.config/sharibako/age-key (mode 0600). Passing \
            --age-key on macOS bypasses the Keychain and Touch ID entirely, which \
            is how the CLI is exercised in scripts and CI.

            BOOTSTRAP

            A fresh install has neither a vault nor a key. 'sharibako key generate' \
            creates both: it generates the age key pair (stored in the Keychain on \
            macOS, or written to a file with --age-key) and scaffolds the vault \
            directory. From there, 'sharibako init' inside a project reads its \
            .env and walks each detected secret through an import decision.

            EXIT CODES

            0 success; 1 generic failure; 2 caller error (bad arguments, unknown \
            scope or key); 3 filesystem/I/O error; 4 age (encryption/decryption) \
            error; 5 git error; 6 Keychain/authentication error; 130 the user \
            declined or cancelled an interactive prompt. 'sharibako run' is the \
            exception: it exec-replaces into your command, so its exit code is the \
            command's own - including 128+signum when the command dies on a signal.

            EXAMPLES

            Bootstrap a key and vault, then a project:
              sharibako key generate
              cd ~/Projects/bento && sharibako init

            Run a dev server with the scope's secrets injected, nothing on disk:
              sharibako run -- npm run dev

            Rotate a shared key once; every linked scope picks up the new value:
              sharibako rotate --shared openai-personal --value "sk-..."
            """,
        version: SharibakoCore.version,
        subcommands: [
            KeyCommand.self,
            InitCommand.self,
            StatusCommand.self,
            ScanCommand.self,
            ListCommand.self,
            HealCommand.self,
            GetCommand.self,
            AddCommand.self,
            RotateCommand.self,
            LinkCommand.self,
            UnlinkCommand.self,
            MaterializeCommand.self,
            RunCommand.self,
            UpdateCommand.self,
            SyncCommand.self,
            CleanCommand.self,
            DeleteCommand.self,
        ]
    )
}
