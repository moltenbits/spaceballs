import ArgumentParser
import Foundation
import SpaceballsCore
import SpaceballsGUILib

struct WorkspaceCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "workspace",
    abstract: "Restore or list workspace configurations",
    subcommands: [RestoreWorkspaceCommand.self, ListWorkspacesCommand.self]
  )
}

struct RestoreWorkspaceCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "restore",
    abstract: "Restore workspaces: create spaces and launch configured apps"
  )

  @Argument(help: "Workspace names to restore (all if omitted)")
  var names: [String] = []

  func run() throws {
    let settings = AppSettings()
    let manager = SpaceManager()
    let store = SpaceNameStore()

    var workspaces = settings.workspaces
    if !names.isEmpty {
      workspaces = workspaces.filter { ws in
        names.contains(where: { $0.localizedCaseInsensitiveCompare(ws.name) == .orderedSame })
      }
      guard !workspaces.isEmpty else {
        throw ValidationError(
          "No workspaces found matching: \(names.joined(separator: ", ")). "
            + "Use 'spaceballs workspace list' to see configured workspaces.")
      }
    }

    guard !workspaces.isEmpty else {
      print("No workspaces configured. Add them in Settings > Spaces.")
      return
    }

    let restorer = WorkspaceRestorer(spaceManager: manager, spaceNameStore: store)
    let data = workspaces.map { ws in
      WorkspaceConfigData(
        name: ws.name,
        path: ws.path,
        launchers: ws.launchers.map { l in
          LauncherData(
            label: l.label, type: l.type.rawValue, command: l.command, appName: l.appName)
        }
      )
    }

    let summary = try restorer.restoreSync(
      workspaces: data,
      defaultNames: settings.customSpaceNames,
      progress: { completed, total, name in
        print("[\(completed + 1)/\(total)] Restoring \(name)...")
      }
    )

    print("\nDone.")
    if summary.spacesCreated > 0 {
      print("  Spaces created: \(summary.spacesCreated)")
    }
    if summary.appsLaunched > 0 {
      print("  Apps launched: \(summary.appsLaunched)")
    }
    for error in summary.errors {
      let launcher = error.launcher.isEmpty ? "" : " (\(error.launcher))"
      print("  Error in \(error.workspace)\(launcher): \(error.error)")
    }
  }
}

struct ListWorkspacesCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "Show configured workspaces and their launchers"
  )

  @Flag(name: .long, help: "Output as JSON")
  var json = false

  func run() throws {
    let settings = AppSettings()

    if json {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(settings.workspaces)
      print(String(data: data, encoding: .utf8)!)
      return
    }

    guard !settings.workspaces.isEmpty else {
      print("No workspaces configured.")
      return
    }

    for ws in settings.workspaces {
      let pathStr = ws.path.map { " (\($0))" } ?? ""
      let launcherCount = ws.launchers.count
      let badge =
        launcherCount == 0
        ? "no apps" : "\(launcherCount) app\(launcherCount == 1 ? "" : "s")"
      print("  \(ws.name)\(pathStr) — \(badge)")
      for launcher in ws.launchers {
        let typeIcon: String
        switch launcher.type {
        case .shell: typeIcon = "⌘"
        case .applescript: typeIcon = "📜"
        case .open: typeIcon = "📂"
        }
        print("    \(typeIcon) \(launcher.label): \(launcher.command)")
      }
    }
  }
}
