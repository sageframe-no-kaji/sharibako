import ArgumentParser
import SharibakoCore

/// Root entry point for the `sharibako` CLI.
///
/// Registers every subcommand. Commands that are not yet implemented
/// (AT-02 write verbs) will be added here when they land.
struct SharibakoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sharibako",
        abstract: "A local encrypted secrets vault, backed by age and git.",
        version: SharibakoCore.version,
        subcommands: [
            KeyCommand.self,
            StatusCommand.self,
            ScanCommand.self,
            ListCommand.self,
            HealCommand.self,
        ]
    )
}
