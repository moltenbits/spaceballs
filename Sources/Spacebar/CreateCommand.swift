import ArgumentParser
import Foundation
import SpacebarCore

struct CreateCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "create",
    abstract: "Create new desktop Space(s)"
  )

  @Argument(help: "Number of spaces to create")
  var count: Int = 1

  func validate() throws {
    guard count >= 1 else {
      throw ValidationError("Count must be at least 1.")
    }
  }

  func run() throws {
    let manager = SpaceManager()
    try manager.createSpaceSync(count: count)

    // Wait for Mission Control animation to finish
    Thread.sleep(forTimeInterval: 1.0)

    print("Created \(count) space\(count == 1 ? "" : "s")")
  }
}
