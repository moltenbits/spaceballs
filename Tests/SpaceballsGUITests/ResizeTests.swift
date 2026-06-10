import Foundation
import Testing

@testable import SpaceballsCore
@testable import SpaceballsGUILib

// MARK: - ResizePreset Tests

@Suite("ResizePreset")
struct ResizePresetTests {
  @Test("Codable round-trip preserves values")
  func codableRoundTrip() throws {
    let preset = ResizePreset(
      name: "Left Third",
      region: GridRegion(
        column: 0, row: 0, columnSpan: 4, rowSpan: 12,
        gridColumns: 12, gridRows: 12
      ),
      keyCode: 0  // A
    )
    let data = try JSONEncoder().encode(preset)
    let decoded = try JSONDecoder().decode(ResizePreset.self, from: data)
    #expect(decoded.name == "Left Third")
    #expect(decoded.region == preset.region)
    #expect(decoded.keyCode == 0)
    #expect(decoded.id == preset.id)
  }

  @Test("Preset with nil keyCode round-trips")
  func nilKeyCodeRoundTrip() throws {
    let preset = ResizePreset(
      name: "Custom",
      region: GridRegion(
        column: 2, row: 2, columnSpan: 8, rowSpan: 8,
        gridColumns: 12, gridRows: 12
      ),
      keyCode: nil
    )
    let data = try JSONEncoder().encode(preset)
    let decoded = try JSONDecoder().decode(ResizePreset.self, from: data)
    #expect(decoded.keyCode == nil)
    #expect(decoded.name == "Custom")
  }

  @Test("Default presets use 12x12 grid")
  func defaultPresetsGrid() {
    let presets = ResizePreset.defaultPresets()
    #expect(!presets.isEmpty)
    for preset in presets {
      #expect(preset.region.gridColumns == 12)
      #expect(preset.region.gridRows == 12)
    }
  }

  @Test("Default presets include Full Screen")
  func defaultPresetsContainFullScreen() {
    let presets = ResizePreset.defaultPresets()
    let full = presets.first(where: { $0.name == "Full Screen" })
    #expect(full != nil)
    #expect(full?.region.column == 0)
    #expect(full?.region.row == 0)
    #expect(full?.region.columnSpan == 12)
    #expect(full?.region.rowSpan == 12)
    #expect(full?.keyCode == 3)  // F
  }

  @Test("Default presets include Left Half and Right Half")
  func defaultPresetsHalves() {
    let presets = ResizePreset.defaultPresets()
    let left = presets.first(where: { $0.name == "Left Half" })
    let right = presets.first(where: { $0.name == "Right Half" })
    #expect(left != nil)
    #expect(right != nil)
    #expect(left?.region.columnSpan == 6)
    #expect(right?.region.column == 6)
    #expect(right?.region.columnSpan == 6)
  }

  @Test("Default presets have unique IDs")
  func defaultPresetsUniqueIDs() {
    let presets = ResizePreset.defaultPresets()
    let ids = Set(presets.map(\.id))
    #expect(ids.count == presets.count)
  }

  @Test("Default presets have unique key codes")
  func defaultPresetsUniqueKeyCodes() {
    let presets = ResizePreset.defaultPresets()
    let codes = presets.compactMap(\.keyCode)
    let uniqueCodes = Set(codes)
    #expect(uniqueCodes.count == codes.count)
  }
}

// MARK: - AppSettings Resize Persistence Tests

@Suite("AppSettings Resize Persistence")
struct AppSettingsResizeTests {
  private func makeSettings() -> (AppSettings, UserDefaults, String) {
    let suiteName = "com.moltenbits.spaceballs.test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let settings = AppSettings(defaults: defaults)
    return (settings, defaults, suiteName)
  }

  @Test("Resize grid defaults to 12x12")
  func resizeGridDefaults() {
    let (settings, defaults, suiteName) = makeSettings()
    #expect(settings.resizeGridColumns == 12)
    #expect(settings.resizeGridRows == 12)
    #expect(settings.resizeMargins == 0)
    defaults.removePersistentDomain(forName: suiteName)
  }

  @Test("Resize grid columns persists")
  func resizeGridColumnsPersist() {
    let suiteName = "com.moltenbits.spaceballs.test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!

    let settings1 = AppSettings(defaults: defaults)
    settings1.resizeGridColumns = 8

    let settings2 = AppSettings(defaults: defaults)
    #expect(settings2.resizeGridColumns == 8)

    defaults.removePersistentDomain(forName: suiteName)
  }

  @Test("Resize grid rows persists")
  func resizeGridRowsPersist() {
    let suiteName = "com.moltenbits.spaceballs.test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!

    let settings1 = AppSettings(defaults: defaults)
    settings1.resizeGridRows = 16

    let settings2 = AppSettings(defaults: defaults)
    #expect(settings2.resizeGridRows == 16)

    defaults.removePersistentDomain(forName: suiteName)
  }

  @Test("Resize margins persists")
  func resizeMarginsPersist() {
    let suiteName = "com.moltenbits.spaceballs.test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!

    let settings1 = AppSettings(defaults: defaults)
    settings1.resizeMargins = 10

    let settings2 = AppSettings(defaults: defaults)
    #expect(settings2.resizeMargins == 10)

    defaults.removePersistentDomain(forName: suiteName)
  }

  @Test("Resize presets persist")
  func resizePresetsPersist() {
    let suiteName = "com.moltenbits.spaceballs.test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!

    let settings1 = AppSettings(defaults: defaults)
    let customPreset = ResizePreset(
      name: "Custom",
      region: GridRegion(
        column: 1, row: 1, columnSpan: 10, rowSpan: 10,
        gridColumns: 12, gridRows: 12
      ),
      keyCode: 7  // X
    )
    settings1.resizePresets = [customPreset]

    let settings2 = AppSettings(defaults: defaults)
    #expect(settings2.resizePresets.count == 1)
    #expect(settings2.resizePresets[0].name == "Custom")
    #expect(settings2.resizePresets[0].keyCode == 7)
    #expect(settings2.resizePresets[0].region.columnSpan == 10)

    defaults.removePersistentDomain(forName: suiteName)
  }

  @Test("Default presets loaded when no saved presets exist")
  func defaultPresetsOnFreshInit() {
    let (settings, defaults, suiteName) = makeSettings()
    #expect(!settings.resizePresets.isEmpty)
    #expect(settings.resizePresets.first?.name == "Full Screen")
    defaults.removePersistentDomain(forName: suiteName)
  }
}

// MARK: - Settings Export Resize Tests

@Suite("Settings Export Resize")
struct SettingsExportResizeTests {
  @Test("Round-trip export/import preserves resize settings")
  func roundTrip() throws {
    let defaults1 = UserDefaults(suiteName: "test.resize.export.\(UUID().uuidString)")!
    let settings1 = AppSettings(defaults: defaults1)
    settings1.resizeGridColumns = 8
    settings1.resizeGridRows = 10
    settings1.resizeMargins = 5
    settings1.resizePresets = [
      ResizePreset(
        name: "Test",
        region: GridRegion(
          column: 0, row: 0, columnSpan: 4, rowSpan: 5,
          gridColumns: 8, gridRows: 10
        ),
        keyCode: 6  // Z
      )
    ]

    let data = try SettingsExport.exportJSON(settings: settings1)

    let defaults2 = UserDefaults(suiteName: "test.resize.import.\(UUID().uuidString)")!
    let settings2 = AppSettings(defaults: defaults2)
    try SettingsExport.importJSON(data, settings: settings2)

    #expect(settings2.resizeGridColumns == 8)
    #expect(settings2.resizeGridRows == 10)
    #expect(settings2.resizeMargins == 5)
    #expect(settings2.resizePresets.count == 1)
    #expect(settings2.resizePresets[0].name == "Test")
    #expect(settings2.resizePresets[0].keyCode == 6)
    #expect(settings2.resizePresets[0].region.gridColumns == 8)
  }

  @Test("Import without resize fields uses defaults")
  func importLegacyWithoutResize() throws {
    // Simulate a legacy export JSON that has no resize fields
    let legacyJSON = """
      {
        "showAppIcons": true,
        "showCurrentBadge": true,
        "showDisplayBadge": true,
        "showEmptySpaces": true,
        "filterSpacesByDisplay": false,
        "colorScheme": "auto",
        "textSize": 13,
        "panelDisplay": "active",
        "spaceSortOrder": "mru",
        "excludedBundleIDs": [],
        "keyBindings": {},
        "workspaces": []
      }
      """
    let data = legacyJSON.data(using: .utf8)!

    let defaults = UserDefaults(suiteName: "test.resize.legacy.\(UUID().uuidString)")!
    let settings = AppSettings(defaults: defaults)
    try SettingsExport.importJSON(data, settings: settings)

    #expect(settings.resizeGridColumns == 12)
    #expect(settings.resizeGridRows == 12)
    #expect(settings.resizeMargins == 0)
    #expect(!settings.resizePresets.isEmpty)  // defaults applied
  }
}

// MARK: - KeyBindings showResize Tests

@Suite("KeyBindings showResize")
struct KeyBindingsShowResizeTests {
  @Test("showResize defaults to keyCode 2 (D)")
  func showResizeDefault() {
    let bindings = KeyBindings()
    #expect(bindings.showResize == 2)
  }

  @Test("showResize accessible via subscript")
  func showResizeSubscript() {
    let bindings = KeyBindings()
    #expect(bindings[.showResize] == 2)
  }

  @Test("showResize settable via subscript")
  func showResizeSubscriptSet() {
    var bindings = KeyBindings()
    bindings[.showResize] = 7
    #expect(bindings.showResize == 7)
  }

  @Test("ShortcutAction.showResize has correct label")
  func showResizeLabel() {
    #expect(ShortcutAction.showResize.label == "Show resize grid")
  }

  @Test("showResize survives codable round-trip")
  func showResizeCodable() throws {
    let original = KeyBindings(showResize: 42)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(KeyBindings.self, from: data)
    #expect(decoded.showResize == 42)
  }

  @Test("Backward-compatible decode defaults showResize to 2")
  func backwardCompatibleDecode() throws {
    // JSON without showResize field
    let json = """
      {
        "activateAndNext": 48,
        "previousItem": 50,
        "nextSpace": 125,
        "previousSpace": 126,
        "nextDisplay": 124,
        "previousDisplay": 123,
        "renameSpace": 15,
        "cycleSortOrder": 1,
        "createSpace": 45,
        "closeWindow": 13,
        "quitApp": 12,
        "moveWindow": 46,
        "cancel": 53
      }
      """
    let data = json.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(KeyBindings.self, from: data)
    #expect(decoded.showResize == 2)
  }
}
