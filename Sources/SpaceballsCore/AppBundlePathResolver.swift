import Foundation

public enum AppBundlePathResolver {
  /// Resolve symlinks before checking bundle ancestry.
  ///
  /// Local installs and Homebrew casks expose `spaceballs` as a symlink into
  /// `Spaceballs-CLI.app`. macOS permissions and WindowServer app registration
  /// are tied to the resolved `.app` process identity, not the symlink path.
  public static func resolvedExecutablePath(_ executablePath: String) -> String {
    URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().standardized.path
  }

  public static func containingAppBundlePath(forExecutablePath executablePath: String) -> String? {
    containingAppBundlePath(in: resolvedExecutablePath(executablePath))
  }

  static func containingAppBundlePath(in executablePath: String) -> String? {
    let components = URL(fileURLWithPath: executablePath).standardized.pathComponents
    guard let appIndex = components.lastIndex(where: { $0.hasSuffix(".app") }) else {
      return nil
    }

    let afterApp = components.dropFirst(appIndex + 1)
    guard afterApp.count >= 2 else { return nil }

    let contentsIndex = afterApp.startIndex
    let macOSIndex = afterApp.index(afterApp.startIndex, offsetBy: 1)
    guard afterApp[contentsIndex] == "Contents", afterApp[macOSIndex] == "MacOS" else {
      return nil
    }

    return NSURL.fileURL(withPathComponents: Array(components[...appIndex]))?.path
  }
}
