import ArgumentParser
import SpaceballsCore

struct MCMoveSpaceTestCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "mc-move-space-test",
    abstract: "Drag a space tile to another display via Mission Control drag simulation"
  )

  @Argument(help: "Exact space tile title (e.g., \"Desktop 2\")")
  var tileTitle: String

  @Argument(help: "Target display: name substring, UUID, or 1-based ordinal")
  var display: String

  @Flag(name: .shortAndLong, help: "Print diagnostic output")
  var verbose = false

  func run() throws {
    let manager = SpaceManager()
    let candidates = MoveSpaceCommand.displayCandidates(from: manager.getAllSpaces())

    guard
      case .resolved(let uuid) = DisplayArgumentResolver.resolve(display, displays: candidates),
      let screenNumber = SpaceManager.displayIDForUUID(uuid)
    else {
      print("Could not resolve display \"\(display)\"")
      throw ExitCode.failure
    }

    let ok = manager.moveSpaceInMC(
      spaceTileTitle: tileTitle, targetScreenNumber: screenNumber, verbose: verbose)
    if !ok {
      throw ExitCode.failure
    }
  }
}
