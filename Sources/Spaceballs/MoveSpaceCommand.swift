import ArgumentParser
import SpaceballsCore

struct MoveSpaceCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "move-space",
    abstract: "Move an entire space to another display"
  )

  @Argument(help: "Space ID, name, or \"Desktop N\" (IDs from 'spaceballs list')")
  var space: String

  @Argument(help: "Target display: name substring, UUID, or 1-based ordinal")
  var display: String

  func run() throws {
    let manager = SpaceManager()
    let spaceNameStore = SpaceNameStore()
    let allSpaces = manager.getAllSpaces()

    // Resolve space — try numeric ID first, then name
    let spaceID: UInt64
    if let id = UInt64(space) {
      spaceID = id
    } else {
      guard let resolved = spaceNameStore.resolveSpaceID(space, spaces: allSpaces) else {
        print("No space matching \"\(space)\"")
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

    // Resolve display against the unique display UUIDs in CGS order, so
    // ordinals match the display grouping in 'spaceballs list'.
    let candidates = Self.displayCandidates(from: allSpaces)
    let targetDisplayUUID: String
    switch DisplayArgumentResolver.resolve(display, displays: candidates) {
    case .resolved(let uuid):
      targetDisplayUUID = uuid
    case .ambiguous(let matches):
      print("Multiple displays match \"\(display)\":")
      Self.printDisplays(matches, within: candidates)
      throw ExitCode.failure
    case .notFound:
      print("No display matching \"\(display)\"")
      print("Available displays:")
      Self.printDisplays(candidates, within: candidates)
      throw ExitCode.failure
    }

    let ok = try manager.moveSpaceToDisplay(spaceID: spaceID, targetDisplayUUID: targetDisplayUUID)
    guard ok else {
      print("Move failed.")
      throw ExitCode.failure
    }

    let displayName =
      SpaceManager.displayNameForUUID(targetDisplayUUID) ?? targetDisplayUUID
    let desktops = allSpaces.filter { $0.type == .desktop }
    let spaceLabel: String
    if let index = desktops.firstIndex(where: { $0.id == spaceID }) {
      spaceLabel =
        spaceNameStore.customName(forSpaceUUID: desktops[index].uuid) ?? "Desktop \(index + 1)"
    } else {
      spaceLabel = "Space \(spaceID)"
    }
    print("Moved \(spaceLabel) to \(displayName).")
  }

  static func displayCandidates(from spaces: [SpaceInfo]) -> [DisplayArgumentResolver.Candidate] {
    var candidates: [DisplayArgumentResolver.Candidate] = []
    for space in spaces where !candidates.contains(where: { $0.uuid == space.displayUUID }) {
      candidates.append(
        DisplayArgumentResolver.Candidate(
          uuid: space.displayUUID,
          name: SpaceManager.displayNameForUUID(space.displayUUID)))
    }
    return candidates
  }

  private static func printDisplays(
    _ displays: [DisplayArgumentResolver.Candidate],
    within all: [DisplayArgumentResolver.Candidate]
  ) {
    for candidate in displays {
      let ordinal = (all.firstIndex(where: { $0.uuid == candidate.uuid }) ?? 0) + 1
      print("  \(ordinal). \(candidate.name ?? "Unknown") (\(candidate.uuid))")
    }
  }
}
