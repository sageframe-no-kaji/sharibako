import ArgumentParser
import SharibakoCore

/// Root entry point for the `sharibako` CLI.
@available(macOS 10.15, *)
@main
struct SharibakoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sharibako",
        abstract: "A local encrypted secrets vault, backed by age and git.",
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
        ]
    )
}
