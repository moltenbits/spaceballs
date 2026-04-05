import ArgumentParser

@main
struct SpaceballsCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "spaceballs",
    abstract: "A macOS window switcher — enumerate Spaces and windows",
    version: SpaceballsVersion.version,
    subcommands: [
      ListCommand.self, WindowCommand.self, RenameCommand.self, SwitchCommand.self,
      CreateCommand.self, CloseSpaceCommand.self, WorkspaceCommand.self, SettingsCommand.self,
    ]
  )
}
