import Foundation
import Testing

@testable import SpaceballsCore

// MARK: - Helpers

private func desktop(
  _ id: UInt64, display: String, current: Bool = false
) -> SpaceInfo {
  SpaceInfo(
    id: id, uuid: "uuid-\(id)", type: .desktop,
    displayUUID: display, isCurrent: current)
}

private func fullscreen(
  _ id: UInt64, display: String, current: Bool = false
) -> SpaceInfo {
  SpaceInfo(
    id: id, uuid: "uuid-\(id)", type: .fullscreen,
    displayUUID: display, isCurrent: current)
}

// MARK: - Space Move Planner

@Suite("Space Move Planner")
struct SpaceMovePlannerTests {

  /// Display A: 1, 2 (2 current) — Display B: 3, 4 (3 current)
  private let twoDisplays: [SpaceInfo] = [
    desktop(1, display: "display-A"),
    desktop(2, display: "display-A", current: true),
    desktop(3, display: "display-B", current: true),
    desktop(4, display: "display-B"),
  ]

  @Test("Non-current space plans a direct move with global tile numbering")
  func directMove() throws {
    let outcome = try SpaceMovePlanner.plan(
      spaceID: 4, targetDisplayUUID: "display-A", spaces: twoDisplays
    ).get()

    guard case .ready(let plan) = outcome else {
      Issue.record("expected .ready, got \(outcome)")
      return
    }
    #expect(plan.spaceID == 4)
    #expect(plan.sourceTileTitle == "Desktop 4")
    #expect(plan.sourceDisplayUUID == "display-B")
    #expect(plan.targetDisplayUUID == "display-A")
    #expect(plan.preSwitch == nil)
  }

  @Test("Global tile numbering skips fullscreen spaces")
  func numberingSkipsFullscreen() throws {
    let spaces: [SpaceInfo] = [
      desktop(1, display: "display-A", current: true),
      fullscreen(90, display: "display-A"),
      desktop(2, display: "display-A"),
      desktop(3, display: "display-B", current: true),
      desktop(4, display: "display-B"),
    ]

    let outcome = try SpaceMovePlanner.plan(
      spaceID: 4, targetDisplayUUID: "display-A", spaces: spaces
    ).get()

    guard case .ready(let plan) = outcome else {
      Issue.record("expected .ready, got \(outcome)")
      return
    }
    // 4 is the 4th desktop space (fullscreen 90 doesn't count).
    #expect(plan.sourceTileTitle == "Desktop 4")
  }

  @Test("Unknown space ID fails with spaceNotFound")
  func unknownSpace() {
    let result = SpaceMovePlanner.plan(
      spaceID: 99, targetDisplayUUID: "display-A", spaces: twoDisplays)
    #expect(result == .failure(.spaceNotFound(spaceID: 99)))
  }

  @Test("Fullscreen space fails with notDesktopSpace")
  func fullscreenSpace() {
    let spaces = twoDisplays + [fullscreen(90, display: "display-B")]
    let result = SpaceMovePlanner.plan(
      spaceID: 90, targetDisplayUUID: "display-A", spaces: spaces)
    #expect(result == .failure(.notDesktopSpace(spaceID: 90)))
  }

  @Test("Space already on the target display fails with alreadyOnTargetDisplay")
  func alreadyOnTarget() {
    let result = SpaceMovePlanner.plan(
      spaceID: 4, targetDisplayUUID: "display-B", spaces: twoDisplays)
    #expect(result == .failure(.alreadyOnTargetDisplay(spaceID: 4)))
  }

  @Test("Unknown target display fails with targetDisplayNotFound")
  func unknownTargetDisplay() {
    let result = SpaceMovePlanner.plan(
      spaceID: 4, targetDisplayUUID: "display-X", spaces: twoDisplays)
    #expect(result == .failure(.targetDisplayNotFound(displayUUID: "display-X")))
  }

  @Test("Only desktop space on its display requires creating a sibling first")
  func onlySpaceNeedsSibling() throws {
    // Display B has a fullscreen space too — it doesn't count as a sibling.
    let spaces: [SpaceInfo] = [
      desktop(1, display: "display-A", current: true),
      desktop(2, display: "display-A"),
      desktop(3, display: "display-B", current: true),
      fullscreen(90, display: "display-B"),
    ]

    let outcome = try SpaceMovePlanner.plan(
      spaceID: 3, targetDisplayUUID: "display-A", spaces: spaces
    ).get()

    #expect(outcome == .createSiblingFirst(onDisplayUUID: "display-B"))
  }

  @Test("Current space plans a pre-switch to the next desktop on its display")
  func currentSpacePreSwitchesToNext() throws {
    let outcome = try SpaceMovePlanner.plan(
      spaceID: 3, targetDisplayUUID: "display-A", spaces: twoDisplays
    ).get()

    guard case .ready(let plan) = outcome else {
      Issue.record("expected .ready, got \(outcome)")
      return
    }
    let preSwitch = try #require(plan.preSwitch)
    #expect(preSwitch.toSpaceID == 4)
    #expect(preSwitch.spaceIndex == 1)  // per-display ordinal of space 4 on display-B
  }

  @Test("Current space that is last on its display pre-switches to the previous sibling")
  func currentLastSpacePreSwitchesToPrevious() throws {
    let spaces: [SpaceInfo] = [
      desktop(1, display: "display-A", current: true),
      desktop(2, display: "display-A"),
      desktop(3, display: "display-B"),
      desktop(4, display: "display-B", current: true),
    ]

    let outcome = try SpaceMovePlanner.plan(
      spaceID: 4, targetDisplayUUID: "display-A", spaces: spaces
    ).get()

    guard case .ready(let plan) = outcome else {
      Issue.record("expected .ready, got \(outcome)")
      return
    }
    let preSwitch = try #require(plan.preSwitch)
    #expect(preSwitch.toSpaceID == 3)
    #expect(preSwitch.spaceIndex == 0)
  }

  @Test("Pre-switch index is the per-display ordinal, not the global one")
  func preSwitchIndexIsPerDisplay() throws {
    // Source display enumerates second; its desktops are 5, 6, 7 with 6 current.
    let spaces: [SpaceInfo] = [
      desktop(1, display: "display-A", current: true),
      desktop(2, display: "display-A"),
      desktop(5, display: "display-B"),
      desktop(6, display: "display-B", current: true),
      desktop(7, display: "display-B"),
    ]

    let outcome = try SpaceMovePlanner.plan(
      spaceID: 6, targetDisplayUUID: "display-A", spaces: spaces
    ).get()

    guard case .ready(let plan) = outcome else {
      Issue.record("expected .ready, got \(outcome)")
      return
    }
    #expect(plan.sourceTileTitle == "Desktop 4")  // global: 1,2,5,6 → 4th
    let preSwitch = try #require(plan.preSwitch)
    #expect(preSwitch.toSpaceID == 7)
    #expect(preSwitch.spaceIndex == 2)  // display-B desktops: 5,6,7 → index 2
  }
}

// MARK: - Display Argument Resolver

@Suite("Display Argument Resolver")
struct DisplayArgumentResolverTests {

  private let displays: [DisplayArgumentResolver.Candidate] = [
    .init(uuid: "AAAA-1111", name: "Built-in Retina Display"),
    .init(uuid: "BBBB-2222", name: "DELL U2723QE"),
    .init(uuid: "CCCC-3333", name: "DELL P2419H"),
  ]

  @Test("Exact UUID match resolves regardless of case")
  func exactUUID() {
    #expect(
      DisplayArgumentResolver.resolve("aaaa-1111", displays: displays)
        == .resolved(uuid: "AAAA-1111"))
  }

  @Test("Integer input resolves as a 1-based ordinal")
  func ordinal() {
    #expect(
      DisplayArgumentResolver.resolve("2", displays: displays)
        == .resolved(uuid: "BBBB-2222"))
  }

  @Test("Ordinal out of range is notFound")
  func ordinalOutOfRange() {
    #expect(DisplayArgumentResolver.resolve("4", displays: displays) == .notFound)
    #expect(DisplayArgumentResolver.resolve("0", displays: displays) == .notFound)
  }

  @Test("Unique case-insensitive name substring resolves")
  func nameSubstring() {
    #expect(
      DisplayArgumentResolver.resolve("retina", displays: displays)
        == .resolved(uuid: "AAAA-1111"))
  }

  @Test("Ambiguous name substring reports all candidates")
  func ambiguousSubstring() {
    #expect(
      DisplayArgumentResolver.resolve("dell", displays: displays)
        == .ambiguous([
          .init(uuid: "BBBB-2222", name: "DELL U2723QE"),
          .init(uuid: "CCCC-3333", name: "DELL P2419H"),
        ]))
  }

  @Test("No match is notFound")
  func noMatch() {
    #expect(DisplayArgumentResolver.resolve("LG", displays: displays) == .notFound)
  }

  @Test("Numeric input prefers ordinal over a name containing the digit")
  func numericPrefersOrdinal() {
    let displays: [DisplayArgumentResolver.Candidate] = [
      .init(uuid: "AAAA-1111", name: "Display 2"),
      .init(uuid: "BBBB-2222", name: "Other"),
    ]
    #expect(
      DisplayArgumentResolver.resolve("2", displays: displays)
        == .resolved(uuid: "BBBB-2222"))
  }
}
