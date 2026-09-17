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
  /// Number of displays the system currently has; bounds the single-display
  /// fallback of `display(matching:)`.
  let activeDisplayCount: Int

  /// The `mc.display` groups, read live: Mission Control can expose displays
  /// one at a time while it opens, so a list captured at first sight may be
  /// short. Callers read this after their settle delay.
  var displays: [AXUIElement] { Self.displays(under: root) }

  static func displays(under root: AXUIElement) -> [AXUIElement] {
    SpaceManager.axChildren(root).filter {
      SpaceManager.axStringAttribute($0, name: "AXIdentifier") == "mc.display"
    }
  }

  /// The `mc.display` group whose `AXDisplayID` is `screenNumber`. On a
  /// single-display system the only group is accepted without an ID match;
  /// with several displays attached, a lone group is a partial snapshot and
  /// must not stand in for a different screen.
  func display(matching screenNumber: CGDirectDisplayID) -> AXUIElement? {
    let displays = self.displays
    if let match = displays.first(where: { Self.displayID(of: $0) == screenNumber }) {
      return match
    }
    return activeDisplayCount == 1 && displays.count == 1 ? displays.first : nil
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
  /// appeared and `mc.display` groups are exposed — under that group, or
  /// under WindowManager when the Dock's group is only a stub — for every
  /// display in `requiredDisplays` (any one display when that is empty).
  /// Returns nil at the deadline. Callers still owe Mission Control its
  /// settle time before interacting: the elements appear before they are
  /// interactive.
  static func awaitMissionControlTree(
    dockElement: AXUIElement, timeout: TimeInterval,
    requiredDisplays: [CGDirectDisplayID] = []
  ) -> MissionControlTree? {
    let deadline = Date().addingTimeInterval(timeout)
    var dockGroup: AXUIElement?
    repeat {
      if dockGroup == nil {
        dockGroup = axChildWithIdentifier(dockElement, identifier: "mc")
      }
      if let dockGroup,
        let tree = missionControlTree(dockGroup: dockGroup, requiredDisplays: requiredDisplays)
      {
        return tree
      }
      Thread.sleep(forTimeInterval: 0.01)
    } while Date() < deadline
    return nil
  }

  private static func missionControlTree(
    dockGroup: AXUIElement, requiredDisplays: [CGDirectDisplayID]
  ) -> MissionControlTree? {
    for root in [dockGroup] + windowManagerElements() {
      let displays = MissionControlTree.displays(under: root)
      guard !displays.isEmpty else { continue }
      let exposed = Set(displays.compactMap(MissionControlTree.displayID(of:)))
      guard requiredDisplays.allSatisfy(exposed.contains) else { continue }
      return MissionControlTree(
        dockGroup: dockGroup, root: root, activeDisplayCount: activeDisplayCount())
    }
    return nil
  }

  static func activeDisplayCount() -> Int {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    return Int(count)
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
  /// `wid` equals `windowID` is the window, wherever it appears. Otherwise the
  /// title heuristics of `matchWindowThumbnail(displayTitles:windowTitle:)`
  /// apply to the thumbnails whose identity is unknown (no `wid`, as on older
  /// trees); one with a known, different `wid` is provably another window and
  /// is never a candidate, however well its title matches.
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
    let candidateTitles = displays.map { thumbnails in
      thumbnails.map { thumbnail -> String? in
        if let windowID, let known = thumbnail.windowID, known != windowID { return nil }
        return thumbnail.title
      }
    }
    return matchWindowThumbnail(displayTitles: candidateTitles, windowTitle: windowTitle)
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

  /// The point to aim at for a tile. A `.center` position IS the tile's
  /// visible center, so it is used as-is. An `.origin` position gives the
  /// horizontal center from the frame, on the bar's vertical center: those
  /// frames are taller than the bar and can sit above it (collapsed-state
  /// reads on portrait displays), so the bar is the only reliable vertical
  /// aim.
  static func dropPoint(
    tilePosition: CGPoint, tileWidth: CGFloat, anchor: TileAnchor, barCenter: CGPoint
  ) -> CGPoint {
    switch anchor {
    case .center: return tilePosition
    case .origin: return CGPoint(x: tilePosition.x + tileWidth / 2, y: barCenter.y)
    }
  }

  /// Live read of where to grab or drop on `tile`, a child of `bar`
  /// (`mc.spaces.list`): `dropPoint` over the bar's current layout. Returns
  /// nil when any tile's position is unreadable: the anchor is inferred from
  /// the whole row's symmetry, and a partial sample can flip it (dropping one
  /// end tile of a centered row reads as origin-anchored). Callers treat nil
  /// as "keep the last aim" and re-read.
  static func aimPoint(tile: AXUIElement, in bar: AXUIElement) -> CGPoint? {
    guard let tilePosition = SpaceManager.axPosition(tile),
      let tileSize = SpaceManager.axSize(tile),
      let barCenter = SpaceManager.axCenter(bar)
    else { return nil }
    let tiles = SpaceManager.axChildren(bar)
    let tileXs = tiles.compactMap { SpaceManager.axPosition($0)?.x }
    guard tileXs.count == tiles.count else { return nil }
    let anchor = tileAnchor(tileXs: tileXs, tileWidth: tileSize.width, barCenterX: barCenter.x)
    return dropPoint(
      tilePosition: tilePosition, tileWidth: tileSize.width, anchor: anchor, barCenter: barCenter)
  }

  /// The child index in a bar of its `desktopIndex`-th desktop tile, skipping
  /// the app-titled tiles fullscreen Spaces add to the same bar. A
  /// per-display desktop index (`perDisplayDesktopIndex`) counts desktops
  /// only, so it must never be applied to the raw child list.
  static func desktopTileChildIndex(titles: [String?], desktopIndex: Int) -> Int? {
    guard desktopIndex >= 0 else { return nil }
    let desktopChildren = titles.indices.filter { isDesktopTile(title: titles[$0]) }
    return desktopChildren.indices.contains(desktopIndex) ? desktopChildren[desktopIndex] : nil
  }

  /// The `desktopIndex`-th desktop tile of a bar (`mc.spaces.list`) and its
  /// title, via `desktopTileChildIndex` over the bar's current children.
  static func desktopTile(
    in bar: AXUIElement, desktopIndex: Int
  ) -> (tile: AXUIElement, title: String)? {
    let children = SpaceManager.axChildren(bar)
    let titles = children.map { SpaceManager.axStringAttribute($0, name: "AXTitle") }
    guard let child = desktopTileChildIndex(titles: titles, desktopIndex: desktopIndex),
      let title = titles[child]
    else { return nil }
    return (children[child], title)
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
