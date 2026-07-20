import ArgumentParser
import CoreGraphics
import SpaceballsCore

struct MCMoveSpaceTestCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "mc-move-space-test",
    abstract: "Drag a space tile to another display via Mission Control drag simulation"
  )

  @Argument(help: "Source display: name substring, UUID, or 1-based ordinal")
  var sourceDisplay: String

  @Argument(help: "0-based index of the space among the source display's desktop tiles")
  var spaceIndex: Int

  @Argument(help: "Target display: name substring, UUID, or 1-based ordinal")
  var targetDisplay: String

  @Flag(name: .shortAndLong, help: "Print diagnostic output")
  var verbose = false

  func run() throws {
    let manager = SpaceManager()
    let candidates = MoveSpaceCommand.displayCandidates(from: manager.getAllSpaces())

    func screen(for input: String) -> CGDirectDisplayID? {
      guard
        case .resolved(let uuid) = DisplayArgumentResolver.resolve(input, displays: candidates)
      else { return nil }
      return SpaceManager.displayIDForUUID(uuid)
    }

    guard let sourceScreen = screen(for: sourceDisplay) else {
      print("Could not resolve source display \"\(sourceDisplay)\"")
      throw ExitCode.failure
    }
    guard let targetScreen = screen(for: targetDisplay) else {
      print("Could not resolve target display \"\(targetDisplay)\"")
      throw ExitCode.failure
    }

    let ok = manager.moveSpaceInMC(
      sourceSpaceIndex: spaceIndex, sourceScreenNumber: sourceScreen,
      targetScreenNumber: targetScreen, verbose: verbose)
    if !ok {
      throw ExitCode.failure
    }
  }
}
