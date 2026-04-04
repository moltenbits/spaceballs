/// Abstracts the system calls that SpaceManager depends on,
/// enabling tests to inject mock data.
public protocol SystemDataSource {
  /// Returns raw display/space dictionaries from CGSCopyManagedDisplaySpaces.
  func fetchManagedDisplaySpaces() -> [[String: Any]]

  /// Returns raw window info dictionaries from CGWindowListCopyWindowInfo(.optionAll).
  func fetchWindowList() -> [[String: Any]]

  /// Returns on-screen window info dictionaries in front-to-back Z-order.
  /// Uses CGWindowListCopyWindowInfo(.optionOnScreenOnly) which guarantees ordering.
  func fetchOnScreenWindowList() -> [[String: Any]]

  /// Returns the space IDs that the given window belongs to.
  func fetchSpacesForWindow(_ windowID: Int) -> [UInt64]
}
