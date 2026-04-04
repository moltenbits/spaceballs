import ArgumentParser
import Foundation
import SpaceballsCore
import SpaceballsGUILib

struct CreateCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "create",
    abstract: "Create new desktop Space(s)"
  )

  @Flag(name: .long, help: "Create missing spaces from your default space names list")
  var defaults = false

  @Argument(
    help: "Number of spaces to create, or a name for the new space (ignored with --defaults)")
  var argument: String?

  func validate() throws {
    if !defaults, let arg = argument, let n = Int(arg), n < 1 {
      throw ValidationError("Count must be at least 1.")
    }
  }

  func run() throws {
    let manager = SpaceManager()
    let store = SpaceNameStore()

    if defaults {
      let settings = AppSettings()
      let defaultNames = settings.customSpaceNames
      guard !defaultNames.isEmpty else {
        print("No default space names defined. Add them in Settings > Spaces.")
        return
      }

      let created = try manager.createDefaultSpacesSync(
        defaultNames: defaultNames, spaceNameStore: store)
      if created > 0 {
        print("Created \(created) space\(created == 1 ? "" : "s")")
      } else {
        print("All default spaces already exist.")
      }
    } else if let arg = argument, Int(arg) == nil {
      try manager.createNamedSpaceSync(name: arg, spaceNameStore: store)
      print("Created space \"\(arg)\"")
    } else {
      let count = argument.flatMap(Int.init) ?? 1
      try manager.createSpaceSync(count: count)
      Thread.sleep(forTimeInterval: 1.0)
      print("Created \(count) space\(count == 1 ? "" : "s")")
    }
  }
}
