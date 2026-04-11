import ArgumentParser
import SpaceballsCore

struct MoveCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "move",
    abstract: "Move a window to another space"
  )

  @Argument(help: "Window ID or title substring (IDs from 'spaceballs list')")
  var window: String

  @Argument(help: "Target space ID, name, or \"Desktop N\" (IDs from 'spaceballs list')")
  var targetSpace: String

  func run() throws {
    let manager = SpaceManager()
    let spaceNameStore = SpaceNameStore()

    // Resolve window — try numeric ID first, then title substring
    let windowID: Int
    if let id = Int(window) {
      windowID = id
    } else {
      let allWindows = manager.getAllWindows()
      let matches = allWindows.filter {
        if let name = $0.name {
          return name.localizedCaseInsensitiveContains(window)
        }
        return $0.ownerName.localizedCaseInsensitiveContains(window)
      }

      guard !matches.isEmpty else {
        print("No window matching \"\(window)\"")
        print("Available windows:")
        for w in allWindows {
          print("  [\(w.id)] \(w.ownerName) — \(w.name ?? "(untitled)")")
        }
        throw ExitCode.failure
      }

      guard matches.count == 1 else {
        print("Multiple windows match \"\(window)\":")
        for w in matches {
          print("  [\(w.id)] \(w.ownerName) — \(w.name ?? "(untitled)")")
        }
        print("Use a window ID to disambiguate.")
        throw ExitCode.failure
      }

      windowID = matches[0].id
    }

    // Resolve space — try numeric ID first, then name
    let spaceID: UInt64
    if let id = UInt64(targetSpace) {
      spaceID = id
    } else {
      let allSpaces = manager.getAllSpaces()
      guard let resolved = spaceNameStore.resolveSpaceID(targetSpace, spaces: allSpaces) else {
        print("No space matching \"\(targetSpace)\"")
        print("Available spaces:")
        var ordinal = 0
        for s in allSpaces where s.type == .desktop {
          ordinal += 1
          let label = spaceNameStore.customName(forSpaceUUID: s.uuid) ?? "Desktop \(ordinal)"
          print("  [\(s.id)] \(label)")
        }
        throw ExitCode.failure
      }
      spaceID = resolved
    }

    let ok = try manager.moveWindowToSpace(windowID: windowID, targetSpaceID: spaceID)
    if !ok {
      print("Move failed.")
      throw ExitCode.failure
    }
  }
}
