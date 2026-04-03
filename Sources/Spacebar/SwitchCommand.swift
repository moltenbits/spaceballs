import ArgumentParser
import Foundation
import SpacebarCore

struct SwitchCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "switch",
    abstract: "Switch to a Space by its ID or name"
  )

  @Argument(
    help:
      "The Space ID or name to switch to (from 'spacebar list'). Accepts a numeric ID, a custom space name, or a default label like \"Desktop 2\"."
  )
  var space: String

  func run() throws {
    let manager = SpaceManager()
    let spaceID = try resolveSpaceID(space, manager: manager)
    try manager.switchToSpace(id: spaceID)

    // switchToSpace dispatches async work via Dock AX:
    // ~1s poll for Mission Control + 0.3s animation wait + button press.
    Thread.sleep(forTimeInterval: 2.0)
  }

  private func resolveSpaceID(_ input: String, manager: SpaceManager) throws -> UInt64 {
    // Try as numeric ID first
    if let id = UInt64(input) {
      return id
    }

    // Otherwise match by name (custom name or default "Desktop N" label)
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
