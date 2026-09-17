import CoreGraphics
import Testing

@testable import SpaceballsCore

/// Where to drop on a spaces-bar tile, given how Mission Control reports
/// tile positions: top-left origins through macOS 26, frame centers under
/// the WindowManager-hosted tree on macOS 27.
@Suite("Mission Control Tile Geometry")
struct MissionControlTileGeometryTests {

  @Test("A center-anchored tile is aimed at exactly as reported")
  func centerAnchoredDropPoint() {
    let bar = CGPoint(x: 900, y: 97)
    #expect(
      MissionControlTree.dropPoint(
        tilePosition: CGPoint(x: 900, y: 125), tileWidth: 168, anchor: .center, barCenter: bar)
        == CGPoint(x: 900, y: 125))
  }

  @Test("An origin-anchored tile is aimed at its horizontal center on the bar's vertical center")
  func originAnchoredDropPoint() {
    let bar = CGPoint(x: 900, y: 97)
    #expect(
      MissionControlTree.dropPoint(
        tilePosition: CGPoint(x: 816, y: -40), tileWidth: 168, anchor: .origin, barCenter: bar)
        == CGPoint(x: 900, y: 97))
  }
}

@Suite("Mission Control Desktop Tiles")
struct MissionControlDesktopTileTests {
  @Test("Numbered desktops and the bare Desktop of a single-space display count")
  func desktopTitles() {
    #expect(MissionControlTree.isDesktopTile(title: "Desktop 1"))
    #expect(MissionControlTree.isDesktopTile(title: "Desktop 12"))
    #expect(MissionControlTree.isDesktopTile(title: "Desktop"))
  }

  @Test("App-titled fullscreen tiles and missing titles don't")
  func nonDesktopTitles() {
    #expect(!MissionControlTree.isDesktopTile(title: "Safari"))
    #expect(!MissionControlTree.isDesktopTile(title: "Desktop Pictures"))
    #expect(!MissionControlTree.isDesktopTile(title: nil))
  }
}

@Suite("Mission Control Desktop Tile Index")
struct MissionControlDesktopTileIndexTests {
  @Test("A fullscreen tile between desktops does not shift the desktop index")
  func fullscreenTileBetweenDesktops() {
    let titles: [String?] = ["Desktop 1", "Safari", "Desktop 2"]
    #expect(MissionControlTree.desktopTileChildIndex(titles: titles, desktopIndex: 1) == 2)
    #expect(MissionControlTree.desktopTileChildIndex(titles: titles, desktopIndex: 0) == 0)
  }

  @Test("A fullscreen tile before the desktops does not shift the desktop index")
  func fullscreenTileFirst() {
    let titles: [String?] = ["Xcode", "Desktop 1", "Desktop 2"]
    #expect(MissionControlTree.desktopTileChildIndex(titles: titles, desktopIndex: 0) == 1)
  }

  @Test("A display's only desktop, titled just Desktop, is index 0")
  func bareDesktop() {
    #expect(MissionControlTree.desktopTileChildIndex(titles: ["Desktop"], desktopIndex: 0) == 0)
  }

  @Test("Out-of-range and negative indices resolve to nil")
  func outOfRange() {
    let titles: [String?] = ["Desktop 1", "Safari"]
    #expect(MissionControlTree.desktopTileChildIndex(titles: titles, desktopIndex: 1) == nil)
    #expect(MissionControlTree.desktopTileChildIndex(titles: titles, desktopIndex: -1) == nil)
  }
}

@Suite("Mission Control Bar Expansion")
struct MissionControlBarExpansionTests {
  typealias Reading = MissionControlTree.BarReading

  private func collapsed(x: CGFloat) -> Reading {
    Reading(
      barFrame: CGRect(x: 0, y: 0, width: 1800, height: 78),
      tileFrame: CGRect(x: x, y: 5, width: 168, height: 129), aim: CGPoint(x: x, y: 5))
  }

  private func expanded(x: CGFloat, y: CGFloat = 125) -> Reading {
    Reading(
      barFrame: CGRect(x: 0, y: 0, width: 1800, height: 194),
      tileFrame: CGRect(x: x, y: y, width: 168, height: 129), aim: CGPoint(x: x, y: y))
  }

  @Test("Collapsed readings never satisfy the wait, even when stable")
  func collapsedIsNotAccepted() {
    var reads = [collapsed(x: 899), collapsed(x: 899), collapsed(x: 899)]
    let result = MissionControlTree.awaitExpandedAim(
      maxAttempts: 3, read: { reads.isEmpty ? nil : reads.removeFirst() }, delay: {})
    #expect(result?.expanded == false)
    #expect(result?.aim == CGPoint(x: 899, y: 5))
  }

  @Test("The wait rides out expansion and returns the first settled expanded aim")
  func settlesAfterExpansion() {
    var reads = [
      collapsed(x: 899), collapsed(x: 899),
      expanded(x: 850, y: 110), expanded(x: 890, y: 122), expanded(x: 900), expanded(x: 900),
    ]
    var attempts = 0
    let result = MissionControlTree.awaitExpandedAim(
      read: {
        attempts += 1
        return reads.isEmpty ? nil : reads.removeFirst()
      }, delay: {})
    #expect(result?.expanded == true)
    #expect(result?.aim == CGPoint(x: 900, y: 125))
    #expect(attempts == 6)
  }

  @Test("An already-expanded bar settles on its second reading")
  func alreadyExpanded() {
    var reads = [expanded(x: 900), expanded(x: 900)]
    let result = MissionControlTree.awaitExpandedAim(
      read: { reads.isEmpty ? nil : reads.removeFirst() }, delay: {})
    #expect(result?.expanded == true)
    #expect(result?.aim == CGPoint(x: 900, y: 125))
  }

  @Test("A failed read breaks the agreement streak")
  func failedReadBreaksStreak() {
    var reads: [Reading?] = [expanded(x: 900), nil, expanded(x: 900), expanded(x: 900)]
    var attempts = 0
    let result = MissionControlTree.awaitExpandedAim(
      read: {
        attempts += 1
        return reads.isEmpty ? nil : reads.removeFirst()
      }, delay: {})
    #expect(result?.expanded == true)
    #expect(attempts == 4)
  }

  @Test("Nothing readable resolves to nil")
  func nothingReadable() {
    let result = MissionControlTree.awaitExpandedAim(maxAttempts: 3, read: { nil }, delay: {})
    #expect(result == nil)
  }
}

/// The decision callers act on: a point to grab/drop, or nil meaning fail.
@Suite("Mission Control Tile Location Decision")
struct MissionControlTileLocationTests {
  typealias Reading = MissionControlTree.BarReading

  private func collapsed(x: CGFloat) -> Reading {
    Reading(
      barFrame: CGRect(x: 0, y: 0, width: 1800, height: 78),
      tileFrame: CGRect(x: x, y: 5, width: 168, height: 129), aim: CGPoint(x: x, y: 5))
  }

  private func expanded(x: CGFloat) -> Reading {
    Reading(
      barFrame: CGRect(x: 0, y: 0, width: 1800, height: 194),
      tileFrame: CGRect(x: x, y: 125, width: 168, height: 129), aim: CGPoint(x: x, y: 125))
  }

  @Test("WindowManager host: a bar that never expands yields no point")
  func centerNeverExpanded() {
    let point = MissionControlTree.locateTile(
      anchor: .center, read: { self.collapsed(x: 900) }, delay: {})
    #expect(point == nil)
  }

  @Test("WindowManager host: a tile that vanished after one reading yields no point")
  func centerVanishedAfterFirstRead() {
    var reads: [Reading?] = [expanded(x: 900)]
    let point = MissionControlTree.locateTile(
      anchor: .center, read: { reads.isEmpty ? nil : reads.removeFirst() }, delay: {})
    #expect(point == nil)
  }

  @Test("WindowManager host: confirmed expansion yields the settled center")
  func centerExpanded() {
    var reads = [collapsed(x: 899), expanded(x: 880), expanded(x: 900), expanded(x: 900)]
    let point = MissionControlTree.locateTile(
      anchor: .center, read: { reads.isEmpty ? nil : reads.removeFirst() }, delay: {})
    #expect(point == CGPoint(x: 900, y: 125))
  }

  @Test("Dock host: two agreeing readings suffice, without an expansion predicate")
  func originStableSuffices() {
    var reads = [collapsed(x: 899), collapsed(x: 899)]
    let point = MissionControlTree.locateTile(
      anchor: .origin, read: { reads.isEmpty ? nil : reads.removeFirst() }, delay: {})
    #expect(point == CGPoint(x: 899, y: 5))
  }

  @Test("Dock host: readings that never agree yield no point")
  func originNeverStable() {
    var x: CGFloat = 0
    let point = MissionControlTree.locateTile(
      anchor: .origin,
      read: {
        x += 10
        return self.collapsed(x: x)
      }, delay: {})
    #expect(point == nil)
  }
}
