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

  @Test("Drop point uses the tile's true horizontal center on the bar's vertical center")
  func dropPoint() {
    let bar = CGPoint(x: 900, y: 97)
    #expect(
      MissionControlTree.dropPoint(tileX: 900, tileWidth: 168, anchor: .center, barCenter: bar)
        == CGPoint(x: 900, y: 97))
    #expect(
      MissionControlTree.dropPoint(tileX: 816, tileWidth: 168, anchor: .origin, barCenter: bar)
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
