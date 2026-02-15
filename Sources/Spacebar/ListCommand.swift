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

    if json {
      try printJSON(spaces: spaces, windowMap: windowMap)
    } else {
      printText(spaces: spaces, windowMap: windowMap)
    }
  }
}
