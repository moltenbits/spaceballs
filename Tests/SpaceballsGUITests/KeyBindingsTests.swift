import Foundation
import Testing

@testable import SpaceballsGUILib

// MARK: - KeyBindings Tests

@Suite("KeyBindings")
struct KeyBindingsTests {
  @Test("Default values match expected key codes")
  func defaultValues() {
    let bindings = KeyBindings()
    #expect(bindings.activateAndNext == 48)
    #expect(bindings.previousItem == 50)
    #expect(bindings.nextSpace == 125)
    #expect(bindings.previousSpace == 126)
    #expect(bindings.nextDisplay == 124)
    #expect(bindings.previousDisplay == 123)
    #expect(bindings.renameSpace == 15)
    #expect(bindings.closeWindow == 13)
    #expect(bindings.quitApp == 12)
    #expect(bindings.cancel == 53)
  }

  @Test("Custom init overrides specific keys")
  func customInit() {
    let bindings = KeyBindings(activateAndNext: 49, renameSpace: 0, cancel: 36)
    #expect(bindings.activateAndNext == 49)
    #expect(bindings.previousItem == 50)  // default
    #expect(bindings.renameSpace == 0)
    #expect(bindings.cancel == 36)
    #expect(bindings.closeWindow == 13)  // default
  }

  @Test("Codable round-trip preserves values")
  func codableRoundTrip() throws {
    let original = KeyBindings(
      activateAndNext: 49,
      previousItem: 36,
      nextSpace: 38,
      previousSpace: 40,
      nextDisplay: 37,
      previousDisplay: 34,
      renameSpace: 0
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(KeyBindings.self, from: data)
    #expect(decoded == original)
  }

  @Test("Subscript get returns correct property for each action")
  func subscriptGet() {
    let bindings = KeyBindings()
    #expect(bindings[.activateAndNext] == 48)
    #expect(bindings[.previousItem] == 50)
    #expect(bindings[.nextSpace] == 125)
    #expect(bindings[.previousSpace] == 126)
    #expect(bindings[.nextDisplay] == 124)
    #expect(bindings[.previousDisplay] == 123)
    #expect(bindings[.renameSpace] == 15)
    #expect(bindings[.closeWindow] == 13)
    #expect(bindings[.quitApp] == 12)
    #expect(bindings[.cancel] == 53)
  }

  @Test("Subscript set updates correct property")
  func subscriptSet() {
    var bindings = KeyBindings()
    bindings[.activateAndNext] = 99
    #expect(bindings.activateAndNext == 99)
    #expect(bindings.previousItem == 50)  // unchanged

    bindings[.renameSpace] = 7
    #expect(bindings.renameSpace == 7)
  }

  @Test("No conflicts with default bindings")
  func noConflictsOnDefaults() {
    let bindings = KeyBindings()
    #expect(bindings.conflicts().isEmpty)
  }

  @Test("Detects conflict when two actions share a key")
  func detectsSingleConflict() {
    var bindings = KeyBindings()
    bindings.previousItem = 48  // same as activateAndNext
    let conflicts = bindings.conflicts()
    #expect(conflicts.count == 1)
    #expect(conflicts[0].0 == .activateAndNext)
    #expect(conflicts[0].1 == .previousItem)
  }

  @Test("Detects multiple conflicts")
  func detectsMultipleConflicts() {
    var bindings = KeyBindings()
    bindings.previousItem = 48  // conflicts with activateAndNext
    bindings.nextSpace = 48  // also conflicts with activateAndNext
    let conflicts = bindings.conflicts()
    #expect(conflicts.count == 2)
  }

  @Test("Equatable: identical bindings are equal")
  func equatable() {
    let a = KeyBindings()
    let b = KeyBindings()
    #expect(a == b)
  }

  @Test("Equatable: different bindings are not equal")
  func equatableNotEqual() {
    let a = KeyBindings()
    let b = KeyBindings(activateAndNext: 99)
    #expect(a != b)
  }
}

// MARK: - KeyCodeNames Tests

@Suite("KeyCodeNames")
struct KeyCodeNamesTests {
  @Test("Known key codes return readable names")
  func knownKeyCodes() {
    #expect(KeyCodeNames.displayName(for: 48) == "Tab")
    #expect(KeyCodeNames.displayName(for: 50) == "`")
    #expect(KeyCodeNames.displayName(for: 125) == "↓")
    #expect(KeyCodeNames.displayName(for: 126) == "↑")
    #expect(KeyCodeNames.displayName(for: 124) == "→")
    #expect(KeyCodeNames.displayName(for: 123) == "←")
    #expect(KeyCodeNames.displayName(for: 45) == "N")
    #expect(KeyCodeNames.displayName(for: 49) == "Space")
    #expect(KeyCodeNames.displayName(for: 36) == "Return")
    #expect(KeyCodeNames.displayName(for: 53) == "Escape")
  }

  @Test("Unknown key code returns fallback string")
  func unknownKeyCode() {
    #expect(KeyCodeNames.displayName(for: 999) == "Key 999")
  }

  @Test("Letter key codes map correctly")
  func letterKeys() {
    #expect(KeyCodeNames.displayName(for: 0) == "A")
    #expect(KeyCodeNames.displayName(for: 6) == "Z")
    #expect(KeyCodeNames.displayName(for: 13) == "W")
    #expect(KeyCodeNames.displayName(for: 12) == "Q")
  }

  @Test("F-keys map correctly")
  func fKeys() {
    #expect(KeyCodeNames.displayName(for: 122) == "F1")
    #expect(KeyCodeNames.displayName(for: 111) == "F12")
  }
}

// MARK: - AppSettings KeyBindings Persistence Tests

@Suite("AppSettings KeyBindings Persistence")
struct AppSettingsKeyBindingsTests {
  private func makeIsolatedSettings() -> (AppSettings, UserDefaults) {
    let suiteName = "com.moltenbits.spaceballs.test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let settings = AppSettings(defaults: defaults)
    return (settings, defaults)
  }

  private func cleanUp(_ defaults: UserDefaults, suiteName: String) {
    defaults.removePersistentDomain(forName: suiteName)
  }

  @Test("Default keyBindings when no UserDefaults data exists")
  func defaultKeyBindings() {
    let (settings, _) = makeIsolatedSettings()
    #expect(settings.keyBindings == KeyBindings())
  }

  @Test("keyBindings persists to UserDefaults and loads back")
  func keyBindingsPersistence() {
    let suiteName = "com.moltenbits.spaceballs.test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!

    // Write custom bindings
    let settings1 = AppSettings(defaults: defaults)
    settings1.keyBindings = KeyBindings(activateAndNext: 49, renameSpace: 0)

    // Load from same defaults — should get the custom bindings
    let settings2 = AppSettings(defaults: defaults)
    #expect(settings2.keyBindings.activateAndNext == 49)
    #expect(settings2.keyBindings.renameSpace == 0)
    #expect(settings2.keyBindings.previousItem == 50)  // default

    defaults.removePersistentDomain(forName: suiteName)
  }

  @Test("isRecordingShortcut defaults to false and is not persisted")
  func isRecordingShortcutTransient() {
    let suiteName = "com.moltenbits.spaceballs.test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!

    let settings1 = AppSettings(defaults: defaults)
    #expect(settings1.isRecordingShortcut == false)

    settings1.isRecordingShortcut = true

    // New instance should still be false (not persisted)
    let settings2 = AppSettings(defaults: defaults)
    #expect(settings2.isRecordingShortcut == false)

    defaults.removePersistentDomain(forName: suiteName)
  }
}
