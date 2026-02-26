import Foundation

// MARK: - Protocol

public protocol SpaceNameStoring {
  func customName(forSpaceUUID uuid: String) -> String?
  func setCustomName(_ name: String?, forSpaceUUID uuid: String)
  func allCustomNames() -> [String: String]
}

// MARK: - UserDefaults Implementation

public final class SpaceNameStore: SpaceNameStoring {
  private static let key = "customSpaceNames"
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = UserDefaults(suiteName: "com.moltenbits.spacebar.shared")!) {
    self.defaults = defaults
    Self.migrateIfNeeded(to: defaults)
  }

  public func customName(forSpaceUUID uuid: String) -> String? {
    allCustomNames()[uuid]
  }

  public func setCustomName(_ name: String?, forSpaceUUID uuid: String) {
    var names = allCustomNames()
    if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      names[uuid] = name
    } else {
      names.removeValue(forKey: uuid)
    }
    defaults.set(names, forKey: Self.key)
  }

  public func allCustomNames() -> [String: String] {
    defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
  }

  // MARK: - Migration

  /// One-time migration from the old UserDefaults location.
  ///
  /// Before the shared suite, names were stored in `UserDefaults.standard`
  /// which maps to `com.moltenbits.spacebar` when running from the .app bundle.
  /// From the .app, `.standard` IS that domain. From the CLI,
  /// `UserDefaults(suiteName: "com.moltenbits.spacebar")` reads it.
  private static func migrateIfNeeded(to defaults: UserDefaults) {
    guard defaults.dictionary(forKey: key) == nil else { return }

    // From the .app bundle, .standard is the old domain
    if let oldNames = UserDefaults.standard.dictionary(forKey: key) as? [String: String],
      !oldNames.isEmpty
    {
      defaults.set(oldNames, forKey: key)
      UserDefaults.standard.removeObject(forKey: key)
      return
    }

    // From the CLI, read the .app's old domain explicitly
    if let oldSuite = UserDefaults(suiteName: "com.moltenbits.spacebar"),
      let oldNames = oldSuite.dictionary(forKey: key) as? [String: String],
      !oldNames.isEmpty
    {
      defaults.set(oldNames, forKey: key)
      oldSuite.removeObject(forKey: key)
    }
  }
}
