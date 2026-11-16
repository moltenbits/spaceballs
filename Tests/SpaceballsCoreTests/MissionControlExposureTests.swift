import CoreGraphics
import Testing

@testable import SpaceballsCore

/// Where Mission Control's accessibility tree is found, and whether Mission
/// Control counts as open, for what the Dock and WindowManager expose on each
/// macOS: the Dock's `mc` group holds the `mc.display` groups through macOS
/// 26; on macOS 27.0 that group is an empty stub and WindowManager holds
/// them; from macOS 27.2 the Dock exposes no `mc` group at all.
@Suite("Mission Control Exposure")
struct MissionControlExposureTests {
  typealias Exposure = MissionControlExposure<String>

  private func holder(_ element: String, _ displayIDs: [CGDirectDisplayID?])
    -> Exposure.DisplayHolder
  {
    Exposure.DisplayHolder(element: element, displayIDs: displayIDs)
  }

  // MARK: macOS 27.2 — no Dock group, WindowManager holds the displays

  @Test("WindowManager's displays are found when the Dock exposes no mc group")
  func windowManagerWithoutDockGroup() {
    let exposure = Exposure(
      dockGroup: nil, windowManager: [holder("window-manager", [2, 1, 3, 4])])

    let root = exposure.root(requiring: [])

    #expect(root?.element == "window-manager")
    #expect(root?.host == .windowManager)
  }

  @Test("Mission Control is open when WindowManager exposes displays and the Dock no mc group")
  func openWithoutDockGroup() {
    let exposure = Exposure(dockGroup: nil, windowManager: [holder("window-manager", [1])])

    #expect(exposure.isOpen)
  }

  @Test("A required display must be among WindowManager's when the Dock exposes no mc group")
  func requiredDisplayWithoutDockGroup() {
    let exposure = Exposure(dockGroup: nil, windowManager: [holder("window-manager", [1, 2])])

    #expect(exposure.root(requiring: [2])?.element == "window-manager")
    #expect(exposure.root(requiring: [3]) == nil)
  }

  // MARK: macOS 27.0 — empty Dock group, WindowManager holds the displays

  @Test("WindowManager's displays are found when the Dock's mc group is empty")
  func windowManagerBehindEmptyDockGroup() {
    let exposure = Exposure(
      dockGroup: holder("dock-mc", []), windowManager: [holder("window-manager", [1, 2])])

    let root = exposure.root(requiring: [1, 2])

    #expect(root?.element == "window-manager")
    #expect(root?.host == .windowManager)
  }

  @Test("Mission Control is open while the Dock exposes an mc group, even an empty one")
  func openWithEmptyDockGroup() {
    let exposure = Exposure(dockGroup: holder("dock-mc", []), windowManager: [holder("wm", [])])

    #expect(exposure.isOpen)
    #expect(exposure.root(requiring: []) == nil)
  }

  // MARK: macOS 26 and earlier — the Dock group holds the displays

  @Test("The Dock's mc group is the root when it holds the displays")
  func dockGroupHoldsDisplays() {
    let exposure = Exposure(
      dockGroup: holder("dock-mc", [1, 2]), windowManager: [holder("window-manager", [])])

    let root = exposure.root(requiring: [2])

    #expect(root?.element == "dock-mc")
    #expect(root?.host == .dock)
  }

  // MARK: Closed and partial states

  @Test("Mission Control is closed when neither process exposes anything")
  func closed() {
    let exposure = Exposure(dockGroup: nil, windowManager: [holder("window-manager", [])])

    #expect(!exposure.isOpen)
    #expect(exposure.root(requiring: []) == nil)
  }

  @Test("Mission Control is closed when WindowManager is not running and the Dock has no mc group")
  func closedWithoutWindowManager() {
    let exposure = Exposure(dockGroup: nil, windowManager: [])

    #expect(!exposure.isOpen)
    #expect(exposure.root(requiring: []) == nil)
  }

  @Test("No root is found until every required display is exposed")
  func requiredDisplayNotYetExposed() {
    let exposure = Exposure(
      dockGroup: holder("dock-mc", []), windowManager: [holder("window-manager", [1])])

    #expect(exposure.root(requiring: [1, 2]) == nil)
  }

  @Test("A display group without a readable ID satisfies no required display")
  func unreadableDisplayID() {
    let exposure = Exposure(dockGroup: nil, windowManager: [holder("window-manager", [nil])])

    #expect(exposure.root(requiring: [])?.element == "window-manager")
    #expect(exposure.root(requiring: [1]) == nil)
  }
}
