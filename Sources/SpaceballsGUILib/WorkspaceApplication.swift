import Foundation

/// Identity read from an application chosen for a workspace launcher.
public struct WorkspaceApplication: Equatable {
  public let url: URL
  public let name: String
  public let bundleID: String

  public init?(url: URL) {
    guard url.isFileURL, url.pathExtension.lowercased() == "app",
      let bundle = Bundle(url: url),
      let identifier = bundle.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
      !identifier.isEmpty
    else { return nil }

    self.url = url
    bundleID = identifier
    name =
      ["CFBundleDisplayName", "CFBundleName"]
      .compactMap { bundle.object(forInfoDictionaryKey: $0) as? String }
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty } ?? url.deletingPathExtension().lastPathComponent
  }
}
