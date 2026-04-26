import Foundation
import Testing

@testable import SpaceballsCore

@Suite("GridRegion")
struct GridRegionTests {
  @Test("Codable round-trip preserves values")
  func codableRoundTrip() throws {
    let region = GridRegion(
      column: 2, row: 1, columnSpan: 4, rowSpan: 3,
      gridColumns: 12, gridRows: 12
    )
    let data = try JSONEncoder().encode(region)
    let decoded = try JSONDecoder().decode(GridRegion.self, from: data)
    #expect(decoded == region)
  }

  @Test("Equatable: identical regions are equal")
  func equatable() {
    let a = GridRegion(column: 0, row: 0, columnSpan: 6, rowSpan: 6, gridColumns: 12, gridRows: 12)
    let b = GridRegion(column: 0, row: 0, columnSpan: 6, rowSpan: 6, gridColumns: 12, gridRows: 12)
    #expect(a == b)
  }

  @Test("Equatable: different regions are not equal")
  func notEqual() {
    let a = GridRegion(column: 0, row: 0, columnSpan: 6, rowSpan: 6, gridColumns: 12, gridRows: 12)
    let b = GridRegion(column: 6, row: 0, columnSpan: 6, rowSpan: 6, gridColumns: 12, gridRows: 12)
    #expect(a != b)
  }

  @Test("Hashable: equal regions produce same hash")
  func hashable() {
    let a = GridRegion(column: 0, row: 0, columnSpan: 6, rowSpan: 12, gridColumns: 12, gridRows: 12)
    let b = GridRegion(column: 0, row: 0, columnSpan: 6, rowSpan: 12, gridColumns: 12, gridRows: 12)
    #expect(a.hashValue == b.hashValue)
  }
}

@Suite("WindowResizer Frame Calculation")
struct WindowResizerFrameTests {
  // Create a mock screen for testing. We can't construct NSScreen directly,
  // so we test the frame calculation logic directly.

  @Test("Full screen region covers entire visible area")
  func fullScreenRegion() {
    let region = GridRegion(
      column: 0, row: 0, columnSpan: 6, rowSpan: 6,
      gridColumns: 6, gridRows: 6
    )
    // visibleFrame in Cocoa coords: origin (0, 0), size (1920, 1055)
    // primary screen height: 1080 (menu bar takes 25px)
    // Full region should span the entire visible area
    let visibleFrame = CGRect(x: 0, y: 0, width: 1920, height: 1055)
    let primaryHeight: CGFloat = 1080

    let frame = computeTargetFrame(
      for: region, visibleFrame: visibleFrame,
      primaryHeight: primaryHeight, margins: 0)

    #expect(frame.origin.x == 0)
    #expect(frame.width == 1920)
    #expect(frame.height == 1055)
  }

  @Test("Left half region covers left 50%")
  func leftHalfRegion() {
    let region = GridRegion(
      column: 0, row: 0, columnSpan: 3, rowSpan: 6,
      gridColumns: 6, gridRows: 6
    )
    let visibleFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let primaryHeight: CGFloat = 1080

    let frame = computeTargetFrame(
      for: region, visibleFrame: visibleFrame,
      primaryHeight: primaryHeight, margins: 0)

    #expect(frame.origin.x == 0)
    #expect(frame.width == 960)
    #expect(frame.height == 1080)
  }

  @Test("Right half region starts at midpoint")
  func rightHalfRegion() {
    let region = GridRegion(
      column: 3, row: 0, columnSpan: 3, rowSpan: 6,
      gridColumns: 6, gridRows: 6
    )
    let visibleFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let primaryHeight: CGFloat = 1080

    let frame = computeTargetFrame(
      for: region, visibleFrame: visibleFrame,
      primaryHeight: primaryHeight, margins: 0)

    #expect(frame.origin.x == 960)
    #expect(frame.width == 960)
  }

  @Test("Margins reduce size and offset position")
  func marginsApplied() {
    let region = GridRegion(
      column: 0, row: 0, columnSpan: 6, rowSpan: 6,
      gridColumns: 6, gridRows: 6
    )
    let visibleFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let primaryHeight: CGFloat = 800

    let frame = computeTargetFrame(
      for: region, visibleFrame: visibleFrame,
      primaryHeight: primaryHeight, margins: 10)

    #expect(frame.origin.x == 10)
    #expect(frame.width == 1180)  // 1200 - 2*10
    #expect(frame.height == 780)  // 800 - 2*10
  }

  @Test("Quarter region has correct size")
  func quarterRegion() {
    let region = GridRegion(
      column: 0, row: 0, columnSpan: 6, rowSpan: 6,
      gridColumns: 12, gridRows: 12
    )
    let visibleFrame = CGRect(x: 0, y: 0, width: 1200, height: 1200)
    let primaryHeight: CGFloat = 1200

    let frame = computeTargetFrame(
      for: region, visibleFrame: visibleFrame,
      primaryHeight: primaryHeight, margins: 0)

    #expect(frame.width == 600)
    #expect(frame.height == 600)
  }

  @Test("Bottom half region has correct Y position in AX coordinates")
  func bottomHalfAXCoords() {
    let region = GridRegion(
      column: 0, row: 6, columnSpan: 12, rowSpan: 6,
      gridColumns: 12, gridRows: 12
    )
    // visibleFrame starts at y=0 in Cocoa (bottom of screen)
    let visibleFrame = CGRect(x: 0, y: 0, width: 1200, height: 1200)
    let primaryHeight: CGFloat = 1200

    let frame = computeTargetFrame(
      for: region, visibleFrame: visibleFrame,
      primaryHeight: primaryHeight, margins: 0)

    // Bottom half in grid = row 6..11 = lower half of screen
    // In AX coords (top-left origin), lower half starts at y=600
    #expect(frame.origin.y == 600)
    #expect(frame.height == 600)
  }

  // Extracted frame calculation logic matching WindowResizer.targetFrame
  // to test without needing a real NSScreen.
  private func computeTargetFrame(
    for region: GridRegion, visibleFrame: CGRect,
    primaryHeight: CGFloat, margins: CGFloat
  ) -> CGRect {
    let cellWidth = visibleFrame.width / CGFloat(region.gridColumns)
    let cellHeight = visibleFrame.height / CGFloat(region.gridRows)

    let cocoaX = visibleFrame.origin.x + CGFloat(region.column) * cellWidth + margins
    let cocoaY =
      visibleFrame.origin.y + visibleFrame.height
      - CGFloat(region.row + region.rowSpan) * cellHeight + margins
    let width = CGFloat(region.columnSpan) * cellWidth - 2 * margins
    let height = CGFloat(region.rowSpan) * cellHeight - 2 * margins

    let axX = cocoaX
    let axY = primaryHeight - (cocoaY + height)

    return CGRect(x: axX, y: axY, width: max(width, 1), height: max(height, 1))
  }
}

@Suite("WindowResizeError")
struct WindowResizeErrorTests {
  @Test("Error descriptions are human-readable")
  func errorDescriptions() {
    #expect(WindowResizeError.noFrontmostApp.localizedDescription == "No frontmost application")
    #expect(
      WindowResizeError.noFocusedWindow.localizedDescription == "Could not get focused window")
    #expect(
      WindowResizeError.noScreen.localizedDescription == "Could not determine screen for window")
    #expect(
      WindowResizeError.axSetPositionFailed.localizedDescription == "Failed to set window position")
    #expect(WindowResizeError.axSetSizeFailed.localizedDescription == "Failed to set window size")
  }
}
