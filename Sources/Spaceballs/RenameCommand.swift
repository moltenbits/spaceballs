import ArgumentParser
import SpaceballsCore

struct RenameCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "rename",
    abstract: "Set or clear a custom name for a Space"
  )

  @Argument(help: "The Space ID to rename (from 'spaceballs list')")
  var spaceID: UInt64

  @Argument(help: "The custom name to set (omit to clear)")
  var name: String?

  func run() throws {
    let manager = SpaceManager()
    let spaces = manager.getAllSpaces()

    guard let space = spaces.first(where: { $0.id == spaceID }) else {
      throw ValidationError(
        "No space found with ID \(spaceID). Use 'spaceballs list' to see available spaces.")
    }

    let store = SpaceNameStore()

    if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      store.setCustomName(name, forSpaceUUID: space.uuid)
      print("Renamed space \(spaceID) to \"\(name)\"")
    } else {
      store.setCustomName(nil, forSpaceUUID: space.uuid)
      print("Cleared custom name for space \(spaceID)")
    }
  }
}
