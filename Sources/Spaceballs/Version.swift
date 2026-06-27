import Foundation
import SpaceballsCore

enum SpaceballsVersion {
  static let fallbackVersion = "0.1.0"

  static var version: String {
    bundleVersion() ?? fallbackVersion
  }

  private static func bundleVersion() -> String? {
    if let bundleValue = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
      !bundleValue.isEmpty
    {
      return bundleValue
    }

    guard let executablePath = CommandLine.arguments.first,
      let appPath = AppBundlePathResolver.containingAppBundlePath(forExecutablePath: executablePath)
    else {
      return nil
    }

    let infoPlistURL = URL(fileURLWithPath: appPath)
      .appendingPathComponent("Contents/Info.plist")
    guard let infoDictionary = NSDictionary(contentsOf: infoPlistURL) as? [String: Any],
      let plistValue = infoDictionary["CFBundleShortVersionString"] as? String,
      !plistValue.isEmpty
    else {
      return nil
    }

    return plistValue
  }
}
