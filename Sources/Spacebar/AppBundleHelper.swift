import ArgumentParser
import Foundation

/// Shared helpers for re-executing CLI subcommands through the `.app` bundle.
///
/// macOS grants Accessibility permission per-process identity. A bare CLI binary
/// is a different identity from an `.app` bundle, so it doesn't share the GUI's
/// Accessibility grant. Re-executing through the CLI `.app` bundle ensures the
/// command runs as a registered application with its own stable AX identity.
enum AppBundleHelper {

  static func isRunningInAppBundle() -> Bool {
    let execPath = ProcessInfo.processInfo.arguments[0]
    return execPath.contains(".app/Contents/MacOS/")
  }

  /// Searches for the installed `Spacebar-CLI.app` bundle.
  ///
  /// Checks (in order):
  /// 1. `<prefix>/lib/spacebar/Spacebar-CLI.app` relative to the binary
  /// 2. Common install locations (`/usr/local`, `/opt/homebrew`)
  /// 3. Development build at `.build/Spacebar-CLI.app`
  static func findInstalledAppBundle() -> String? {
    let execPath = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
      .resolvingSymlinksInPath().path
    let binDir = (execPath as NSString).deletingLastPathComponent
    let prefixDir = (binDir as NSString).deletingLastPathComponent
    let relativePath = (prefixDir as NSString).appendingPathComponent(
      "lib/spacebar/Spacebar-CLI.app")

    if FileManager.default.fileExists(atPath: relativePath) {
      return relativePath
    }

    let fallbacks = [
      "/usr/local/lib/spacebar/Spacebar-CLI.app",
      "/opt/homebrew/lib/spacebar/Spacebar-CLI.app",
    ]
    for path in fallbacks {
      if FileManager.default.fileExists(atPath: path) {
        return path
      }
    }

    // Development build
    let devPath = (binDir as NSString).appendingPathComponent("../Spacebar-CLI.app")
    let resolved = URL(fileURLWithPath: devPath).standardized.path
    if FileManager.default.fileExists(atPath: resolved) {
      return resolved
    }

    return nil
  }

  /// Re-executes the current command through the `.app` bundle via `open -n -W`.
  ///
  /// Inherits the terminal's stdout/stderr so output is visible to the user.
  static func reexecViaApp(appPath: String, subcommand: String, args: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")

    var openArgs = ["-n", "-W", "-g"]

    if isatty(STDOUT_FILENO) != 0 {
      let ttyPath = String(cString: ttyname(STDOUT_FILENO))
      openArgs += ["--stdout", ttyPath, "--stderr", ttyPath]
    }

    openArgs += [appPath, "--args", subcommand] + args
    process.arguments = openArgs

    try process.run()
    process.waitUntilExit()

    if process.terminationStatus != 0 {
      throw ExitCode(process.terminationStatus)
    }
  }
}
