import ApplicationServices
import Cocoa

/// Where Mission Control's accessibility tree lives.
///
/// Through macOS 26 the Dock exposes an `mc` group whose children are one
/// `mc.display` group per display, each holding `mc.windows` (thumbnails) and
/// `mc.spaces` (the bar). On macOS 27 the Dock still exposes the `mc` group
/// while Mission Control is open — but as an empty stub — and the real tree
/// moved to the WindowManager process: `mc.display` groups are direct children
/// of its application element, window thumbnails are direct children of each
/// display (no `mc.windows` container) carrying a `wid` attribute with their
/// CGWindowID, and the `mc.spaces` → `mc.spaces.list` bar is unchanged.
struct MissionControlTree {
  /// The Dock's `mc` group. Present exactly while Mission Control is open on
  /// every supported macOS, which keeps it the open/closed signal.
  let dockGroup: AXUIElement
  /// Element whose children are the `mc.display` groups.
  let root: AXUIElement
  let displays: [AXUIElement]

  /// The `mc.display` group whose `AXDisplayID` is `screenNumber`, or the only
  /// display when there is just one.
  func display(matching screenNumber: CGDirectDisplayID) -> AXUIElement? {
    if let match = displays.first(where: { Self.displayID(of: $0) == screenNumber }) {
      return match
    }
    return displays.count == 1 ? displays.first : nil
  }

  /// `displays` with the one matching `screenNumber` first; unchanged when
  /// nil or not found.
  func displays(preferring screenNumber: CGDirectDisplayID?) -> [AXUIElement] {
    guard let screenNumber,
      let preferred = displays.first(where: { Self.displayID(of: $0) == screenNumber })
    else { return displays }
    return [preferred] + displays.filter { $0 != preferred }
  }

  static func displayID(of display: AXUIElement) -> CGDirectDisplayID? {
    var valueRef: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(display, "AXDisplayID" as CFString, &valueRef) == .success,
      let id = valueRef as? Int
    else { return nil }
    return CGDirectDisplayID(id)
  }

  /// The window thumbnail buttons of a display: the `mc.windows` children when
  /// that container exists, otherwise the display's direct button children.
  static func windowThumbnails(of display: AXUIElement) -> [AXUIElement] {
    if let container = SpaceManager.axChildWithIdentifier(display, identifier: "mc.windows") {
      return SpaceManager.axChildren(container)
    }
    return SpaceManager.axChildren(display).filter {
      SpaceManager.axStringAttribute($0, name: "AXRole") == "AXButton"
    }
  }

  /// The CGWindowID a thumbnail stands for (`wid`, macOS 27+), if exposed.
  static func windowID(of thumbnail: AXUIElement) -> Int? {
    var valueRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(thumbnail, "wid" as CFString, &valueRef) == .success
    else { return nil }
    return (valueRef as? NSNumber)?.intValue
  }

  static func spacesBar(of display: AXUIElement) -> AXUIElement? {
    SpaceManager.axChildWithIdentifier(display, identifier: "mc.spaces")
  }

  /// `mc.spaces.list`: the desktop tiles of a display's bar.
  static func spacesList(of display: AXUIElement) -> AXUIElement? {
    spacesBar(of: display).flatMap {
      SpaceManager.axChildWithIdentifier($0, identifier: "mc.spaces.list")
    }
  }
}

extension SpaceManager {
  static let windowManagerBundleID = "com.apple.WindowManager"

  /// Polls until Mission Control's tree is readable: the Dock's `mc` group has
  /// appeared and at least one `mc.display` is exposed — under that group, or
  /// under WindowManager when the Dock's group is only a stub. Returns nil at
  /// the deadline. Callers still owe Mission Control its settle time before
  /// interacting: the elements appear before they are interactive.
  static func awaitMissionControlTree(
    dockElement: AXUIElement, timeout: TimeInterval
  ) -> MissionControlTree? {
    let deadline = Date().addingTimeInterval(timeout)
    var dockGroup: AXUIElement?
    repeat {
      if dockGroup == nil {
        dockGroup = axChildWithIdentifier(dockElement, identifier: "mc")
      }
      if let dockGroup, let tree = missionControlTree(dockGroup: dockGroup) {
        return tree
      }
      Thread.sleep(forTimeInterval: 0.01)
    } while Date() < deadline
    return nil
  }

  private static func missionControlTree(dockGroup: AXUIElement) -> MissionControlTree? {
    for root in [dockGroup] + windowManagerElements() {
      let displays = axChildren(root).filter {
        axStringAttribute($0, name: "AXIdentifier") == "mc.display"
      }
      if !displays.isEmpty {
        return MissionControlTree(dockGroup: dockGroup, root: root, displays: displays)
      }
    }
    return nil
  }

  private static func windowManagerElements() -> [AXUIElement] {
    NSRunningApplication.runningApplications(withBundleIdentifier: windowManagerBundleID)
      .map { AXUIElementCreateApplication($0.processIdentifier) }
  }

  /// A Mission Control window thumbnail as seen through AX.
  struct ThumbnailDescriptor: Equatable {
    var title: String?
    /// CGWindowID from the thumbnail's `wid` attribute; nil where MC doesn't expose it.
    var windowID: Int?
  }

  /// Picks the thumbnail for a window from per-display thumbnail lists
  /// (`displays[0]` is the window's own display when known). A thumbnail whose
  /// `wid` equals `windowID` is the window, wherever it appears; without one,
  /// falls back to the title heuristics of `matchWindowThumbnail(displayTitles:windowTitle:)`.
  static func matchWindowThumbnail(
    displays: [[ThumbnailDescriptor]], windowTitle: String, windowID: Int?
  ) -> (display: Int, index: Int)? {
    if let windowID {
      for (display, thumbnails) in displays.enumerated() {
        if let index = thumbnails.firstIndex(where: { $0.windowID == windowID }) {
          return (display, index)
        }
      }
    }
    return matchWindowThumbnail(
      displayTitles: displays.map { $0.map(\.title) }, windowTitle: windowTitle)
  }
}

extension MissionControlTree {
  /// How a spaces-bar tile's `AXPosition` relates to its visible frame.
  enum TileAnchor: Equatable {
    /// Position is the frame's top-left corner (Dock-hosted tree, macOS ≤ 26).
    case origin
    /// Position is the frame's center (WindowManager-hosted tree, macOS 27).
    case center
  }

  /// Infers the tile anchor from the bar's layout. Tiles are laid out
  /// centered in their bar, so their reported x values sit symmetrically
  /// about the bar's center when they are centers, and half a tile width to
  /// its left when they are origins. Whichever reading the layout fits
  /// better wins; a bar without tiles reads as `.origin`.
  static func tileAnchor(tileXs: [CGFloat], tileWidth: CGFloat, barCenterX: CGFloat) -> TileAnchor {
    guard !tileXs.isEmpty else { return .origin }
    let mean = tileXs.reduce(0, +) / CGFloat(tileXs.count)
    let asCenters = abs(mean - barCenterX)
    let asOrigins = abs(mean + tileWidth / 2 - barCenterX)
    return asCenters < asOrigins ? .center : .origin
  }

  /// The point to aim at for a tile: its horizontal center under the
  /// inferred anchor, on the bar's vertical center. A tile's reported height
  /// exceeds the bar's and hangs below it, so the bar's center is the only
  /// reliable vertical aim.
  static func dropPoint(
    tileX: CGFloat, tileWidth: CGFloat, anchor: TileAnchor, barCenter: CGPoint
  ) -> CGPoint {
    let x = anchor == .center ? tileX : tileX + tileWidth / 2
    return CGPoint(x: x, y: barCenter.y)
  }

  /// Live read of where to grab or drop on `tile`, a child of `bar`
  /// (`mc.spaces.list`): `dropPoint` over the bar's current layout.
  static func aimPoint(tile: AXUIElement, in bar: AXUIElement) -> CGPoint? {
    guard let tilePosition = SpaceManager.axPosition(tile),
      let tileSize = SpaceManager.axSize(tile),
      let barCenter = SpaceManager.axCenter(bar)
    else { return nil }
    let anchor = tileAnchor(
      tileXs: SpaceManager.axChildren(bar).compactMap { SpaceManager.axPosition($0)?.x },
      tileWidth: tileSize.width, barCenterX: barCenter.x)
    return dropPoint(
      tileX: tilePosition.x, tileWidth: tileSize.width, anchor: anchor, barCenter: barCenter)
  }

  /// Whether a spaces-bar tile stands for a desktop Space: "Desktop N", or
  /// the bare "Desktop" macOS 27 shows for a display's only desktop.
  /// Fullscreen Spaces show app-titled tiles in the same bar.
  static func isDesktopTile(title: String?) -> Bool {
    guard let title else { return false }
    if title == "Desktop" { return true }
    guard title.hasPrefix("Desktop ") else { return false }
    return Int(title.dropFirst("Desktop ".count)) != nil
  }
}
