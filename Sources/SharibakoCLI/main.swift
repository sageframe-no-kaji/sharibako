import ArgumentParser
import Logging
import SharibakoCore

struct SharibakoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sharibako",
        abstract: "A small local vault for API keys and env vars.",
        version: SharibakoCore.version,
        subcommands: []
    )

    func run() async throws {
        print("sharibako v\(SharibakoCore.version)")
        print("CLI scaffold. Real commands land starting in ho-04.")
    }
}

await SharibakoCommand.main()
