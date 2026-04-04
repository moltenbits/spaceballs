import Foundation

// MARK: - Protocol

public protocol SpaceNameStoring {
  func customName(forSpaceUUID uuid: String) -> String?
  func setCustomName(_ name: String?, forSpaceUUID uuid: String)
  func allCustomNames() -> [String: String]
  func pruneStaleNames(currentSpaces: [SpaceInfo])
  func resolveSpaceID(_ input: String, spaces: [SpaceInfo]) -> UInt64?
}

// MARK: - UserDefaults Implementation

public final class SpaceNameStore: SpaceNameStoring {
  private static let key = "customSpaceNames"
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = UserDefaults(suiteName: "com.moltenbits.spaceballs.shared")!) {
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

  /// Removes name mappings for space UUIDs that no longer exist.
  public func pruneStaleNames(currentSpaces: [SpaceInfo]) {
    let currentUUIDs = Set(currentSpaces.map(\.uuid))
    for (uuid, _) in allCustomNames() where !currentUUIDs.contains(uuid) {
      setCustomName(nil, forSpaceUUID: uuid)
    }
  }

  /// Resolves a space name or numeric ID string to a space ID.
  /// Matches against custom names and default "Desktop N" labels (case-insensitive).
  public func resolveSpaceID(_ input: String, spaces: [SpaceInfo]) -> UInt64? {
    if let id = UInt64(input) {
      return id
    }

    var desktopOrdinal = 0
    for space in spaces where space.type == .desktop {
      desktopOrdinal += 1
      let defaultLabel = "Desktop \(desktopOrdinal)"
      let label = customName(forSpaceUUID: space.uuid) ?? defaultLabel

      if label.localizedCaseInsensitiveCompare(input) == .orderedSame
        || defaultLabel.localizedCaseInsensitiveCompare(input) == .orderedSame
      {
        return space.id
      }
    }
    return nil
  }

  // MARK: - Migration

  /// One-time migration from the old UserDefaults location.
  ///
  /// Before the shared suite, names were stored in `UserDefaults.standard`
  /// which maps to `com.moltenbits.spaceballs` when running from the .app bundle.
  /// From the .app, `.standard` IS that domain. From the CLI,
  /// `UserDefaults(suiteName: "com.moltenbits.spaceballs")` reads it.
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
    if let oldSuite = UserDefaults(suiteName: "com.moltenbits.spaceballs"),
      let oldNames = oldSuite.dictionary(forKey: key) as? [String: String],
      !oldNames.isEmpty
    {
      defaults.set(oldNames, forKey: key)
      oldSuite.removeObject(forKey: key)
    }
  }
}
