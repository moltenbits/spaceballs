import ArgumentParser
import SpacebarCore

struct ListCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List all Spaces and windows"
  )

  @Flag(name: .long, help: "Output as JSON")
  var json = false

  func run() throws {
    let manager = SpaceManager()
    let (spaces, windowMap) = manager.windowsBySpace()
    let spaceNameStore = SpaceNameStore()

    if json {
      try printJSON(spaces: spaces, windowMap: windowMap, spaceNameStore: spaceNameStore)
    } else {
      printText(spaces: spaces, windowMap: windowMap, spaceNameStore: spaceNameStore)
    }
  }
}
