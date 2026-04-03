import ArgumentParser

@main
struct SpacebarCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "spacebar",
    abstract: "A macOS window switcher — enumerate Spaces and windows",
    version: SpacebarVersion.version,
    subcommands: [ListCommand.self, ActivateCommand.self, RenameCommand.self, SwitchCommand.self, CreateCommand.self]
  )
}
