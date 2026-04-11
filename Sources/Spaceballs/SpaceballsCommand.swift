import ArgumentParser

@main
struct SpaceballsCommand: ParsableCommand {
  static let configuration: CommandConfiguration = {
    var subcommands: [ParsableCommand.Type] = [
      ListCommand.self, WindowCommand.self, RenameCommand.self, SwitchCommand.self,
      CreateCommand.self, CloseSpaceCommand.self, WorkspaceCommand.self, SettingsCommand.self,
    ]
    #if DEBUG
      subcommands += [
        MCDumpCommand.self, MCMoveTestCommand.self, MCDebugPositionsCommand.self,
      ]
    #endif
    return CommandConfiguration(
      commandName: "spaceballs",
      abstract: "A macOS window switcher — enumerate Spaces and windows",
      version: SpaceballsVersion.version,
      subcommands: subcommands
    )
  }()
}
