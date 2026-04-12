import Foundation
import SpaceballsCore

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
  public var workspaces: [WorkspaceConfig]
  public var resizeGridColumns: Int
  public var resizeGridRows: Int
  public var resizeMargins: Double
  public var resizePresets: [ResizePreset]

  public init(
    showAppIcons: Bool, showCurrentBadge: Bool, showDisplayBadge: Bool,
    showEmptySpaces: Bool, filterSpacesByDisplay: Bool, colorScheme: String,
    textSize: Double, panelDisplay: String, spaceSortOrder: String,
    excludedBundleIDs: [String], keyBindings: KeyBindings,
    workspaces: [WorkspaceConfig],
    resizeGridColumns: Int = 12, resizeGridRows: Int = 12,
    resizeMargins: Double = 0, resizePresets: [ResizePreset]? = nil
  ) {
    self.showAppIcons = showAppIcons
    self.showCurrentBadge = showCurrentBadge
    self.showDisplayBadge = showDisplayBadge
    self.showEmptySpaces = showEmptySpaces
    self.filterSpacesByDisplay = filterSpacesByDisplay
    self.colorScheme = colorScheme
    self.textSize = textSize
    self.panelDisplay = panelDisplay
    self.spaceSortOrder = spaceSortOrder
    self.excludedBundleIDs = excludedBundleIDs
    self.keyBindings = keyBindings
    self.workspaces = workspaces
    self.resizeGridColumns = resizeGridColumns
    self.resizeGridRows = resizeGridRows
    self.resizeMargins = resizeMargins
    self.resizePresets =
      resizePresets
      ?? ResizePreset.defaultPresets(gridColumns: resizeGridColumns, gridRows: resizeGridRows)
  }

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
      workspaces: settings.workspaces,
      resizeGridColumns: settings.resizeGridColumns,
      resizeGridRows: settings.resizeGridRows,
      resizeMargins: settings.resizeMargins,
      resizePresets: settings.resizePresets
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
    settings.workspaces = workspaces
    settings.resizeGridColumns = resizeGridColumns
    settings.resizeGridRows = resizeGridRows
    settings.resizeMargins = resizeMargins
    settings.resizePresets = resizePresets
  }

  // Support importing legacy exports that used customSpaceNames: [String]
  private enum CodingKeys: String, CodingKey {
    case showAppIcons, showCurrentBadge, showDisplayBadge, showEmptySpaces
    case filterSpacesByDisplay, colorScheme, textSize, panelDisplay, spaceSortOrder
    case excludedBundleIDs, keyBindings, workspaces, customSpaceNames
    case resizeGridColumns, resizeGridRows, resizeMargins, resizePresets
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(showAppIcons, forKey: .showAppIcons)
    try c.encode(showCurrentBadge, forKey: .showCurrentBadge)
    try c.encode(showDisplayBadge, forKey: .showDisplayBadge)
    try c.encode(showEmptySpaces, forKey: .showEmptySpaces)
    try c.encode(filterSpacesByDisplay, forKey: .filterSpacesByDisplay)
    try c.encode(colorScheme, forKey: .colorScheme)
    try c.encode(textSize, forKey: .textSize)
    try c.encode(panelDisplay, forKey: .panelDisplay)
    try c.encode(spaceSortOrder, forKey: .spaceSortOrder)
    try c.encode(excludedBundleIDs, forKey: .excludedBundleIDs)
    try c.encode(keyBindings, forKey: .keyBindings)
    try c.encode(workspaces, forKey: .workspaces)
    try c.encode(resizeGridColumns, forKey: .resizeGridColumns)
    try c.encode(resizeGridRows, forKey: .resizeGridRows)
    try c.encode(resizeMargins, forKey: .resizeMargins)
    try c.encode(resizePresets, forKey: .resizePresets)
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    showAppIcons = try c.decode(Bool.self, forKey: .showAppIcons)
    showCurrentBadge = try c.decode(Bool.self, forKey: .showCurrentBadge)
    showDisplayBadge = try c.decode(Bool.self, forKey: .showDisplayBadge)
    showEmptySpaces = try c.decode(Bool.self, forKey: .showEmptySpaces)
    filterSpacesByDisplay = try c.decode(Bool.self, forKey: .filterSpacesByDisplay)
    colorScheme = try c.decode(String.self, forKey: .colorScheme)
    textSize = try c.decode(Double.self, forKey: .textSize)
    panelDisplay = try c.decode(String.self, forKey: .panelDisplay)
    spaceSortOrder = try c.decode(String.self, forKey: .spaceSortOrder)
    excludedBundleIDs = try c.decode([String].self, forKey: .excludedBundleIDs)
    keyBindings = try c.decode(KeyBindings.self, forKey: .keyBindings)

    // Try new workspaces format, fall back to legacy customSpaceNames
    if let ws = try? c.decode([WorkspaceConfig].self, forKey: .workspaces) {
      workspaces = ws
    } else if let names = try? c.decode([String].self, forKey: .customSpaceNames) {
      workspaces = names.map { WorkspaceConfig(name: $0) }
    } else {
      workspaces = []
    }

    resizeGridColumns = try c.decodeIfPresent(Int.self, forKey: .resizeGridColumns) ?? 12
    resizeGridRows = try c.decodeIfPresent(Int.self, forKey: .resizeGridRows) ?? 12
    resizeMargins = try c.decodeIfPresent(Double.self, forKey: .resizeMargins) ?? 0
    resizePresets =
      try c.decodeIfPresent([ResizePreset].self, forKey: .resizePresets)
      ?? ResizePreset.defaultPresets(gridColumns: resizeGridColumns, gridRows: resizeGridRows)
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
