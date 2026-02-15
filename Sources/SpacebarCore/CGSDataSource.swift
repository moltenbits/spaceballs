import Cocoa

/// Real implementation that calls private CGS/CG APIs.
public struct CGSDataSource: SystemDataSource {
  private let connection: CGSConnectionID

  public init() {
    self.connection = CGSMainConnectionID()
  }

  public func fetchManagedDisplaySpaces() -> [[String: Any]] {
    CGSCopyManagedDisplaySpaces(connection) as? [[String: Any]] ?? []
  }

  public func fetchWindowList() -> [[String: Any]] {
    CGWindowListCopyWindowInfo(
      [.optionAll, .excludeDesktopElements],
      kCGNullWindowID
    ) as? [[String: Any]] ?? []
  }

  public func fetchSpacesForWindow(_ windowID: Int) -> [UInt64] {
    let windowArray = [windowID as CFNumber] as CFArray
    guard
      let result = CGSCopySpacesForWindows(
        connection,
        CGSSpaceMask.all.rawValue,
        windowArray
      ) as? [NSNumber]
    else {
      return []
    }
    return result.map { $0.uint64Value }
  }
}
