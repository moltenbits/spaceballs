import Foundation
import Testing

@testable import SpacebarGUILib

@Suite("AppSettings App Filtering Persistence")
struct AppFilterTests {
  @Test("excludedBundleIDs defaults to empty set")
  func excludedDefault() {
    let suiteName = "com.moltenbits.spacebar.test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let settings = AppSettings(defaults: defaults)
    #expect(settings.excludedBundleIDs.isEmpty)
    defaults.removePersistentDomain(forName: suiteName)
  }

  @Test("excludedBundleIDs persists and loads back")
  func excludedPersistence() {
    let suiteName = "com.moltenbits.spacebar.test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!

    let settings1 = AppSettings(defaults: defaults)
    settings1.excludedBundleIDs = ["com.example.hidden"]

    let settings2 = AppSettings(defaults: defaults)
    #expect(settings2.excludedBundleIDs == ["com.example.hidden"])

    defaults.removePersistentDomain(forName: suiteName)
  }

  @Test("Removing a bundle ID from excludedBundleIDs persists")
  func removeExcluded() {
    let suiteName = "com.moltenbits.spacebar.test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!

    let settings1 = AppSettings(defaults: defaults)
    settings1.excludedBundleIDs = ["com.example.app1", "com.example.app2"]
    settings1.excludedBundleIDs.remove("com.example.app1")

    let settings2 = AppSettings(defaults: defaults)
    #expect(settings2.excludedBundleIDs == ["com.example.app2"])

    defaults.removePersistentDomain(forName: suiteName)
  }
}
