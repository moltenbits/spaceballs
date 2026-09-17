import CoreGraphics
import Testing

@testable import SpaceballsCore

/// Where to drop on a spaces-bar tile, given how Mission Control reports
/// tile positions: top-left origins through macOS 26, frame centers under
/// the WindowManager-hosted tree on macOS 27.
@Suite("Mission Control Tile Geometry")
struct MissionControlTileGeometryTests {

  @Test("Tiles symmetric about the bar center are reported as centers (macOS 27 layout)")
  func centersAreDetected() {
    // Live macOS 27 reading: 7 expanded tiles, 168 wide, on an 1800-wide bar.
    let xs: [CGFloat] = [388, 559, 729, 900, 1070, 1241, 1412]
    #expect(MissionControlTree.tileAnchor(tileXs: xs, tileWidth: 168, barCenterX: 900) == .center)
  }

  @Test("Tiles offset half a width left of the bar center are reported as origins")
  func originsAreDetected() {
    let xs: [CGFloat] = [304, 475, 645, 816, 986, 1157, 1328]
    #expect(MissionControlTree.tileAnchor(tileXs: xs, tileWidth: 168, barCenterX: 900) == .origin)
  }

  @Test("A single tile is classified the same way")
  func singleTile() {
    #expect(MissionControlTree.tileAnchor(tileXs: [900], tileWidth: 80, barCenterX: 900) == .center)
    #expect(MissionControlTree.tileAnchor(tileXs: [860], tileWidth: 80, barCenterX: 900) == .origin)
  }

  @Test("No tiles reads as origin")
  func noTiles() {
    #expect(MissionControlTree.tileAnchor(tileXs: [], tileWidth: 168, barCenterX: 900) == .origin)
  }

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
