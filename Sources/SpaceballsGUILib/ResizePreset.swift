import Foundation
import SpaceballsCore

public struct ResizePreset: Codable, Equatable, Identifiable {
  public var id: UUID
  public var name: String
  public var region: GridRegion
  /// Key code for the shortcut (active while the resize panel is open). `nil` means no shortcut.
  public var keyCode: UInt16?

  public init(
    id: UUID = UUID(), name: String, region: GridRegion, keyCode: UInt16? = nil
  ) {
    self.id = id
    self.name = name
    self.region = region
    self.keyCode = keyCode
  }

  /// Returns a set of common presets using a 12×12 grid.
  public static func defaultPresets(gridColumns: Int = 12, gridRows: Int = 12) -> [ResizePreset] {
    let g = 12  // default presets always use a 12×12 grid
    return [
      ResizePreset(
        name: "Full Screen",
        region: GridRegion(
          column: 0, row: 0, columnSpan: g, rowSpan: g,
          gridColumns: g, gridRows: g),
        keyCode: 3  // F
      ),
      ResizePreset(
        name: "Left Half",
        region: GridRegion(
          column: 0, row: 0, columnSpan: 6, rowSpan: g,
          gridColumns: g, gridRows: g),
        keyCode: 123  // ←
      ),
      ResizePreset(
        name: "Right Half",
        region: GridRegion(
          column: 6, row: 0, columnSpan: 6, rowSpan: g,
          gridColumns: g, gridRows: g),
        keyCode: 124  // →
      ),
      ResizePreset(
        name: "Top Half",
        region: GridRegion(
          column: 0, row: 0, columnSpan: g, rowSpan: 6,
          gridColumns: g, gridRows: g),
        keyCode: 126  // ↑
      ),
      ResizePreset(
        name: "Bottom Half",
        region: GridRegion(
          column: 0, row: 6, columnSpan: g, rowSpan: 6,
          gridColumns: g, gridRows: g),
        keyCode: 125  // ↓
      ),
    ]
  }
}
