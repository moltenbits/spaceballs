import ArgumentParser
import Foundation
import SpacebarCore
import SpacebarGUILib

struct SettingsCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "settings",
    abstract: "Export or import Spacebar settings",
    subcommands: [ExportSettingsCommand.self, ImportSettingsCommand.self]
  )
}

struct ExportSettingsCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "export",
    abstract: "Export settings to a JSON file (or stdout)"
  )

  @Argument(help: "Output file path (prints to stdout if omitted)")
  var path: String?

  func run() throws {
    let settings = AppSettings()
    let data = try SettingsExport.exportJSON(settings: settings)

    if let path {
      let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
      try data.write(to: url)
      print("Settings exported to \(url.path)")
    } else {
      print(String(data: data, encoding: .utf8)!)
    }
  }
}

struct ImportSettingsCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "import",
    abstract: "Import settings from a JSON file"
  )

  @Argument(help: "Path to the JSON settings file")
  var path: String

  func run() throws {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    let data = try Data(contentsOf: url)
    let settings = AppSettings()
    try SettingsExport.importJSON(data, settings: settings)
    print("Settings imported from \(url.path)")
  }
}
