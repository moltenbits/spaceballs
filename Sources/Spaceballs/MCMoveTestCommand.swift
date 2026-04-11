import ArgumentParser
import SpaceballsCore

struct MCMoveTestCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "mc-move-test",
    abstract: "Move a window to another space via Mission Control drag simulation"
  )

  @Argument(help: "Substring to match against window titles")
  var windowTitle: String

  @Argument(help: "Target space title (e.g., \"Desktop 2\")")
  var targetSpace: String

  @Flag(name: .shortAndLong, help: "Print diagnostic output")
  var verbose = false

  func run() throws {
    let manager = SpaceManager()
    let ok = manager.moveWindowInMC(
      windowTitle: windowTitle, targetSpaceTitle: targetSpace, verbose: verbose)
    if !ok {
      throw ExitCode.failure
    }
  }
}
