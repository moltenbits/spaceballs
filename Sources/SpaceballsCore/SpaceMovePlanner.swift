import Foundation

// MARK: - Space Move Plan

/// The resolved inputs for moving a Space to another display via the
/// Mission Control drag. Produced by `SpaceMovePlanner.plan` from a
/// `getAllSpaces()` snapshot; consumed by `SpaceManager.moveSpaceToDisplay`.
public struct SpaceMovePlan: Equatable {
  public let spaceID: UInt64
  /// Index of the space among its display's desktop spaces — the position of
  /// its tile in that display's MC spaces bar. Tiles are located by
  /// per-display position, never by "Desktop N" title: MC numbers desktops in
  /// display-arrangement order (built-in first) while CGS enumerates displays
  /// in an order that can vary between calls, so a globally computed title is
  /// unreliable.
  public let sourceSpaceIndex: Int
  public let sourceDisplayUUID: String
  public let targetDisplayUUID: String
  /// Set when the space is its display's current space: Mission Control will
  /// not let the active space be dragged, so the display must switch to a
  /// sibling first.
  public let preSwitch: PreSwitch?

  public struct PreSwitch: Equatable {
    public let toSpaceID: UInt64
    /// Per-display ordinal among that display's desktop spaces — the index
    /// `switchToSpace(spaceIndex:screenNumber:)` expects.
    public let spaceIndex: Int
  }
}

// MARK: - Planner

public enum SpaceMovePlanner {
  public enum Outcome: Equatable {
    case ready(SpaceMovePlan)
    /// The space is the only desktop space on its display. A sibling must be
    /// created there first (the display can't switch away otherwise); re-plan
    /// with the fresh space list afterwards.
    case createSiblingFirst(onDisplayUUID: String)
  }

  public static func plan(
    spaceID: UInt64, targetDisplayUUID: String, spaces: [SpaceInfo]
  ) -> Result<Outcome, SpaceMoveError> {
    guard let space = spaces.first(where: { $0.id == spaceID }) else {
      return .failure(.spaceNotFound(spaceID: spaceID))
    }
    guard space.type == .desktop else {
      return .failure(.notDesktopSpace(spaceID: spaceID))
    }
    guard spaces.contains(where: { $0.displayUUID == targetDisplayUUID }) else {
      return .failure(.targetDisplayNotFound(displayUUID: targetDisplayUUID))
    }
    guard space.displayUUID != targetDisplayUUID else {
      return .failure(.alreadyOnTargetDisplay(spaceID: spaceID))
    }

    let displayDesktops = spaces.filter {
      $0.displayUUID == space.displayUUID && $0.type == .desktop
    }
    guard displayDesktops.count > 1 else {
      return .success(.createSiblingFirst(onDisplayUUID: space.displayUUID))
    }

    guard let displayOrdinal = displayDesktops.firstIndex(where: { $0.id == spaceID })
    else {
      return .failure(.spaceNotFound(spaceID: spaceID))
    }

    var preSwitch: SpaceMovePlan.PreSwitch?
    if space.isCurrent {
      // Prefer the next sibling; fall back to the previous when the moving
      // space is last on its display. Either way the visual jump is minimal.
      let siblingIndex =
        displayOrdinal + 1 < displayDesktops.count ? displayOrdinal + 1 : displayOrdinal - 1
      preSwitch = SpaceMovePlan.PreSwitch(
        toSpaceID: displayDesktops[siblingIndex].id, spaceIndex: siblingIndex)
    }

    return .success(
      .ready(
        SpaceMovePlan(
          spaceID: spaceID,
          sourceSpaceIndex: displayOrdinal,
          sourceDisplayUUID: space.displayUUID,
          targetDisplayUUID: targetDisplayUUID,
          preSwitch: preSwitch)))
  }
}

// MARK: - Display Argument Resolver

/// Resolves a user-supplied display argument (UUID, 1-based ordinal, or name
/// substring) against the known displays. Pure — callers supply the candidate
/// list, typically the ordered unique display UUIDs from `getAllSpaces()`.
public enum DisplayArgumentResolver {
  public struct Candidate: Equatable {
    public let uuid: String
    public let name: String?

    public init(uuid: String, name: String?) {
      self.uuid = uuid
      self.name = name
    }
  }

  public enum Resolution: Equatable {
    case resolved(uuid: String)
    case ambiguous([Candidate])
    case notFound
  }

  public static func resolve(_ input: String, displays: [Candidate]) -> Resolution {
    if let exact = displays.first(where: { $0.uuid.caseInsensitiveCompare(input) == .orderedSame })
    {
      return .resolved(uuid: exact.uuid)
    }

    if let ordinal = Int(input) {
      guard ordinal >= 1 && ordinal <= displays.count else { return .notFound }
      return .resolved(uuid: displays[ordinal - 1].uuid)
    }

    let nameMatches = displays.filter {
      $0.name?.localizedCaseInsensitiveContains(input) == true
    }
    switch nameMatches.count {
    case 0: return .notFound
    case 1: return .resolved(uuid: nameMatches[0].uuid)
    default: return .ambiguous(nameMatches)
    }
  }
}
