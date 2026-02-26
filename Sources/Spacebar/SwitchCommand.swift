import ArgumentParser
import Foundation
import SpacebarCore

struct SwitchCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "switch",
    abstract: "Switch to a Space by its ID"
  )

  @Argument(help: "The Space ID to switch to (from 'spacebar list')")
  var spaceID: UInt64

  func run() throws {
    let manager = SpaceManager()
    try manager.switchToSpace(id: spaceID)

    // switchToSpace dispatches async work via Dock AX:
    // ~1s poll for Mission Control + 0.3s animation wait + button press.
    Thread.sleep(forTimeInterval: 2.0)
  }
}
