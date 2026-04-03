import ArgumentParser
import Foundation
import SpacebarCore
import SpacebarGUILib

struct CreateCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "create",
    abstract: "Create new desktop Space(s)"
  )

  @Flag(name: .long, help: "Create missing spaces from your default space names list")
  var defaults = false

  @Argument(help: "Number of spaces to create (ignored with --defaults)")
  var count: Int?

  func validate() throws {
    if !defaults {
      let c = count ?? 1
      guard c >= 1 else {
        throw ValidationError("Count must be at least 1.")
      }
    }
  }

  func run() throws {
    let manager = SpaceManager()

    if defaults {
      try createDefaults(manager: manager)
    } else {
      let c = count ?? 1
      try manager.createSpaceSync(count: c)
      Thread.sleep(forTimeInterval: 1.0)
      print("Created \(c) space\(c == 1 ? "" : "s")")
    }
  }

  private func createDefaults(manager: SpaceManager) throws {
    let settings = AppSettings()
    let store = SpaceNameStore()

    let defaultNames = settings.customSpaceNames
    guard !defaultNames.isEmpty else {
      print("No default space names defined. Add them in Settings > Spaces.")
      return
    }

    // Prune stale name mappings for deleted spaces
    let currentUUIDs = Set(manager.getAllSpaces().map(\.uuid))
    for (uuid, _) in store.allCustomNames() where !currentUUIDs.contains(uuid) {
      store.setCustomName(nil, forSpaceUUID: uuid)
    }

    let existingNames = Set(store.allCustomNames().values)
    let missingNames = defaultNames.filter { !existingNames.contains($0) }

    guard !missingNames.isEmpty else {
      print("All default spaces already exist.")
      return
    }

    print("Creating \(missingNames.count) space\(missingNames.count == 1 ? "" : "s"): \(missingNames.joined(separator: ", "))")

    try manager.createSpaceSync(count: missingNames.count)
    Thread.sleep(forTimeInterval: 1.0)

    // Assign names to the newly created unnamed spaces
    let allSpaces = manager.getAllSpaces().filter { $0.type == .desktop }
    let alreadyNamed = Set(store.allCustomNames().keys)
    let unnamedSpaces = allSpaces.filter { !alreadyNamed.contains($0.uuid) }

    for (name, space) in zip(missingNames, unnamedSpaces.suffix(missingNames.count)) {
      store.setCustomName(name, forSpaceUUID: space.uuid)
    }

    print("Done.")
  }
}
