import ArgumentParser
import Foundation
import SpaceballsCore

struct SwitchCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "switch",
    abstract: "Switch to a Space by its ID or name"
  )

  @Argument(
    help:
      "The Space ID or name to switch to (from 'spaceballs list'). Accepts a numeric ID, a custom space name, or a default label like \"Desktop 2\"."
  )
  var space: String

  func run() throws {
    let manager = SpaceManager()
    let store = SpaceNameStore()
    let spaces = manager.getAllSpaces()

    guard let spaceID = store.resolveSpaceID(space, spaces: spaces) else {
      throw ValidationError(
        "No space found matching \"\(space)\". Use 'spaceballs list' to see available spaces."
      )
    }

    try manager.switchToSpace(id: spaceID)
    Thread.sleep(forTimeInterval: 2.0)
  }
}
