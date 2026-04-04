import ArgumentParser
import Foundation
import SpacebarCore
import SpacebarGUILib

struct CloseSpaceCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "close",
    abstract: "Close a Space by its ID or name"
  )

  @Argument(
    help:
      "The Space ID or name to close. Accepts a numeric ID, a custom space name, or a default label like \"Desktop 2\"."
  )
  var space: String

  func run() throws {
    let manager = SpaceManager()
    let spaceID = try resolveSpaceID(space, manager: manager)
    try manager.closeSpaceSync(id: spaceID)

    Thread.sleep(forTimeInterval: 1.0)

    print("Closed space \(space)")
  }

  private func resolveSpaceID(_ input: String, manager: SpaceManager) throws -> UInt64 {
    if let id = UInt64(input) {
      return id
    }

    let spaces = manager.getAllSpaces()
    let store = SpaceNameStore()

    var desktopOrdinal = 0
    for space in spaces where space.type == .desktop {
      desktopOrdinal += 1
      let defaultLabel = "Desktop \(desktopOrdinal)"
      let customName = store.customName(forSpaceUUID: space.uuid)
      let label = customName ?? defaultLabel

      if label.localizedCaseInsensitiveCompare(input) == .orderedSame
        || defaultLabel.localizedCaseInsensitiveCompare(input) == .orderedSame
      {
        return space.id
      }
    }

    throw ValidationError(
      "No space found matching \"\(input)\". Use 'spacebar list' to see available spaces."
    )
  }
}
