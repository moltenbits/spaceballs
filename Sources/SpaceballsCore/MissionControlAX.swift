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

  /// The tile anchor of the tree's host. WindowManager (macOS 27) reports
  /// tile positions as centers; the Dock reported top-left origins. A
  /// property of the host, not a heuristic: inferring it from the row's
  /// symmetry misclassified a two-tile bar, whose row is not centered.
  var tileAnchor: TileAnchor { root == dockGroup ? .origin : .center }

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
  /// (`mc.spaces.list`): `dropPoint` over the bar's current layout under the
  /// host's `anchor`.
  static func aimPoint(
    tile: AXUIElement, in bar: AXUIElement, anchor: TileAnchor
  ) -> CGPoint? {
    guard let tilePosition = SpaceManager.axPosition(tile),
      let tileSize = SpaceManager.axSize(tile),
      let barCenter = SpaceManager.axCenter(bar)
    else { return nil }
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

// MARK: - Spaces bar expansion

extension MissionControlTree {
  /// One read of a bar and one of its tiles, as the expansion poll sees them.
  struct BarReading: Equatable {
    var barFrame: CGRect
    var tileFrame: CGRect
    var aim: CGPoint
  }

  /// Whether a bar reading shows the bar expanded: Mission Control opens
  /// with the spaces bar collapsed to a row of labels (macOS 27: 78pt with
  /// 129pt tiles reported), and grows past its tiles' height once the
  /// cursor hovers it. Tile coordinates read before that are stale the
  /// moment expansion starts.
  static func isExpanded(_ reading: BarReading) -> Bool {
    reading.barFrame.height + 1 >= reading.tileFrame.height
  }

  /// Polls `read` until the bar is expanded AND two consecutive readings
  /// agree (within `tolerance`), calling `delay` between attempts. A
  /// collapsed bar is stable too, which is exactly the trap: a plain
  /// stable-point wait accepts collapsed coordinates before the hover has
  /// taken effect, and the grab then misses the tile once it moves.
  ///
  /// Returns the settled aim with `expanded: true`, or after `maxAttempts`
  /// the last reading with `expanded: false` so a caller can log and decide;
  /// nil when nothing was readable.
  static func awaitExpandedAim(
    tolerance: CGFloat = 2, maxAttempts: Int = 40,
    read: () -> BarReading?, delay: () -> Void
  ) -> (aim: CGPoint, expanded: Bool)? {
    var previous: BarReading?
    var lastSeen: BarReading?
    for attempt in 0..<maxAttempts {
      if attempt > 0 { delay() }
      guard let reading = read() else {
        previous = nil
        continue
      }
      lastSeen = reading
      defer { previous = reading }
      guard isExpanded(reading), let previous, isExpanded(previous) else { continue }
      if abs(previous.aim.x - reading.aim.x) <= tolerance,
        abs(previous.aim.y - reading.aim.y) <= tolerance
      {
        return (reading.aim, true)
      }
    }
    return lastSeen.map { ($0.aim, false) }
  }

  /// Live reader for the tile waits: the bar's frame, the frame of the tile
  /// titled `tileTitle`, and its aim point — all from one sample, so the
  /// expansion check, the aim and the diagnostics describe the same moment.
  static func barReader(
    bar: AXUIElement, tileTitle: String, anchor: TileAnchor
  ) -> () -> BarReading? {
    {
      guard let barPosition = SpaceManager.axPosition(bar),
        let barSize = SpaceManager.axSize(bar),
        let tile = SpaceManager.axChildren(bar).first(where: {
          SpaceManager.axStringAttribute($0, name: "AXTitle") == tileTitle
        }),
        let tilePosition = SpaceManager.axPosition(tile),
        let tileSize = SpaceManager.axSize(tile)
      else { return nil }
      let barFrame = CGRect(origin: barPosition, size: barSize)
      return BarReading(
        barFrame: barFrame,
        tileFrame: CGRect(origin: tilePosition, size: tileSize),
        aim: dropPoint(
          tilePosition: tilePosition, tileWidth: tileSize.width, anchor: anchor,
          barCenter: CGPoint(x: barFrame.midX, y: barFrame.midY)))
    }
  }

  /// Where a tile in a bar can be grabbed or dropped on, or nil when that
  /// could not be established within the budget — a caller must then fail,
  /// never act on a stale point. The strategy is the host's:
  /// - `.center` (WindowManager): the bar must be confirmed expanded and the
  ///   tile settled (`awaitExpandedAim`); a bar that never expands, or a
  ///   tile that vanished after an earlier reading, is a failure.
  /// - `.origin` (Dock): the expansion predicate is unverified against that
  ///   host's frames, so the historical strategy applies — two agreeing
  ///   readings of the aim.
  static func locateTile(
    anchor: TileAnchor, read: () -> BarReading?, delay: () -> Void
  ) -> CGPoint? {
    switch anchor {
    case .center:
      guard let result = awaitExpandedAim(read: read, delay: delay), result.expanded
      else { return nil }
      return result.aim
    case .origin:
      guard let settled = SpaceManager.awaitStablePoint(read: { read()?.aim }, delay: delay),
        settled.isStable
      else { return nil }
      return settled.point
    }
  }

  /// Hovers `bar` so Mission Control expands it, then locates the tile
  /// titled `tileTitle` (`locateTile`), returning where to grab it or nil.
  /// The routine every hover-and-grab flow goes through; logs the outcome
  /// under `mc`.
  static func hoverAndLocateTile(
    titled tileTitle: String, in bar: AXUIElement, anchor: TileAnchor,
    hover: (CGPoint) -> Void
  ) -> CGPoint? {
    guard let barCenter = SpaceManager.axCenter(bar) else { return nil }
    hover(barCenter)
    let read = barReader(bar: bar, tileTitle: tileTitle, anchor: anchor)
    let aim = locateTile(anchor: anchor, read: read, delay: { Thread.sleep(forTimeInterval: 0.04) })
    let reading = read()
    let frames =
      " bar=\(reading.map { SpaceManager.frameString($0.barFrame) } ?? "?")"
      + " tile=\(reading.map { SpaceManager.frameString($0.tileFrame) } ?? "?")"
    if let aim {
      Diagnostics.log(
        "mc",
        "tile \"\(tileTitle)\" located at (\(Int(aim.x)),\(Int(aim.y))) anchor=\(anchor)\(frames)")
    } else {
      Diagnostics.log(
        "mc", "tile \"\(tileTitle)\" NOT located after hover anchor=\(anchor)\(frames)")
    }
    return aim
  }
}
