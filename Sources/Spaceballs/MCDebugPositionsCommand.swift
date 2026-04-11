import ArgumentParser
import SpaceballsCore

/// Manual functional test: grabs a window in Mission Control, drags it over
/// each space (1.5s per space) to verify position accuracy, then drops it
/// on the specified space. Run with `spaceballs mc-debug-pos <window> --drop-on <space>`.
struct MCDebugPositionsCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "mc-debug-pos",
    abstract: "Functional test: drag a window over each space, drop on a specified space"
  )

  @Argument(help: "Substring to match against window titles")
  var windowTitle: String

  @Option(name: .long, help: "Space title to drop on (default: last space visited)")
  var dropOn: String?

  func run() throws {
    let manager = SpaceManager()
    manager.debugMCDragPositions(windowTitle: windowTitle, dropSpaceTitle: dropOn)
  }
}
