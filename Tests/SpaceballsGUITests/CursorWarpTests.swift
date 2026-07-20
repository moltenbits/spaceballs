import Foundation
import Testing

@testable import SpaceballsGUILib

@Suite("Cursor Warp Planner")
struct CursorWarpPlannerTests {

  @Test("Warps when enabled and the target display differs from the cursor's")
  func warpsOnCrossDisplayActivation() {
    #expect(
      CursorWarpPlanner.shouldWarp(
        enabled: true, displayCount: 2,
        cursorDisplayUUID: "display-A", targetDisplayUUID: "display-B"))
  }

  @Test("Never warps when the setting is off")
  func settingOff() {
    #expect(
      !CursorWarpPlanner.shouldWarp(
        enabled: false, displayCount: 2,
        cursorDisplayUUID: "display-A", targetDisplayUUID: "display-B"))
  }

  @Test("Never warps on a single display")
  func singleDisplay() {
    #expect(
      !CursorWarpPlanner.shouldWarp(
        enabled: true, displayCount: 1,
        cursorDisplayUUID: "display-A", targetDisplayUUID: "display-B"))
  }

  @Test("Never warps when the cursor is already on the target display")
  func sameDisplay() {
    #expect(
      !CursorWarpPlanner.shouldWarp(
        enabled: true, displayCount: 2,
        cursorDisplayUUID: "display-A", targetDisplayUUID: "display-A"))
  }

  @Test("Never warps when the cursor's display is unknown")
  func unknownCursorDisplay() {
    #expect(
      !CursorWarpPlanner.shouldWarp(
        enabled: true, displayCount: 2,
        cursorDisplayUUID: nil, targetDisplayUUID: "display-B"))
  }

  @Test("Never warps when the target display is unknown")
  func unknownTargetDisplay() {
    #expect(
      !CursorWarpPlanner.shouldWarp(
        enabled: true, displayCount: 2,
        cursorDisplayUUID: "display-A", targetDisplayUUID: nil))
  }
}

@Suite("AppSettings Cursor Warp Persistence")
struct CursorWarpSettingTests {

  @Test("warpCursorOnActivation defaults to false")
  func defaultsToOff() {
    let suiteName = "com.moltenbits.spaceballs.test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let settings = AppSettings(defaults: defaults)
    #expect(!settings.warpCursorOnActivation)
    defaults.removePersistentDomain(forName: suiteName)
  }

  @Test("warpCursorOnActivation persists and loads back")
  func persistence() {
    let suiteName = "com.moltenbits.spaceballs.test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!

    let settings1 = AppSettings(defaults: defaults)
    settings1.warpCursorOnActivation = true

    let settings2 = AppSettings(defaults: defaults)
    #expect(settings2.warpCursorOnActivation)

    defaults.removePersistentDomain(forName: suiteName)
  }
}
