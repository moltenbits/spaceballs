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

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
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
}
