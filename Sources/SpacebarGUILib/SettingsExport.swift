import Foundation
import SpacebarCore

public struct SettingsExport: Codable {
  public var showAppIcons: Bool
  public var showCurrentBadge: Bool
  public var showDisplayBadge: Bool
  public var showEmptySpaces: Bool
  public var filterSpacesByDisplay: Bool
  public var colorScheme: String
  public var textSize: Double
  public var panelDisplay: String
  public var spaceSortOrder: String
  public var excludedBundleIDs: [String]
  public var keyBindings: KeyBindings
  public var customSpaceNames: [String]

  public static func from(settings: AppSettings) -> SettingsExport {
    SettingsExport(
      showAppIcons: settings.showAppIcons,
      showCurrentBadge: settings.showCurrentBadge,
      showDisplayBadge: settings.showDisplayBadge,
      showEmptySpaces: settings.showEmptySpaces,
      filterSpacesByDisplay: settings.filterSpacesByDisplay,
      colorScheme: settings.colorScheme.rawValue,
      textSize: settings.textSize,
      panelDisplay: settings.panelDisplay.rawValue,
      spaceSortOrder: settings.spaceSortOrder.rawValue,
      excludedBundleIDs: Array(settings.excludedBundleIDs).sorted(),
      keyBindings: settings.keyBindings,
      customSpaceNames: settings.customSpaceNames
    )
  }

  public func apply(to settings: AppSettings) {
    settings.showAppIcons = showAppIcons
    settings.showCurrentBadge = showCurrentBadge
    settings.showDisplayBadge = showDisplayBadge
    settings.showEmptySpaces = showEmptySpaces
    settings.filterSpacesByDisplay = filterSpacesByDisplay
    settings.colorScheme = AppColorScheme(rawValue: colorScheme) ?? .auto
    settings.textSize = textSize
    settings.panelDisplay = PanelDisplay(rawValue: panelDisplay) ?? .active
    settings.spaceSortOrder = SpaceSortOrder(rawValue: spaceSortOrder) ?? .mru
    settings.excludedBundleIDs = Set(excludedBundleIDs)
    settings.keyBindings = keyBindings
    settings.customSpaceNames = customSpaceNames
  }

  public static func exportJSON(settings: AppSettings) throws -> Data {
    let export = SettingsExport.from(settings: settings)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(export)
  }

  public static func importJSON(_ data: Data, settings: AppSettings) throws {
    let export = try JSONDecoder().decode(SettingsExport.self, from: data)
    export.apply(to: settings)
  }
}
