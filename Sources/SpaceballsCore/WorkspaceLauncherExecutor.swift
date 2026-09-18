import AppKit
import Foundation

struct WorkspaceLaunchRequest: Equatable {
  let steps: [WorkspaceLauncherAction]
  let bundleID: String
}

struct WorkspaceLaunchServicesRequest: Equatable {
  let bundleID: String
  let target: URL?
  let arguments: [String]
  let environment: [String: String]
  let createsNewApplicationInstance: Bool
  let activates: Bool
}

/// Owns every workspace launcher execution path. `WorkspaceRestorer` decides
/// when to launch; this type decides how each configured launch mechanism runs.
struct WorkspaceLauncherExecutor {
  typealias ProcessRunner = (URL, [String], Bool) throws -> Void
  typealias LaunchServicesOpener = (WorkspaceLaunchServicesRequest) throws -> Void

  static let live = WorkspaceLauncherExecutor(
    runProcess: runProcess,
    openWithLaunchServices: LaunchServicesWorkspaceOpener.open)

  let runProcess: ProcessRunner
  let openWithLaunchServices: LaunchServicesOpener

  func execute(_ request: WorkspaceLaunchRequest) throws {
    guard !request.steps.isEmpty else {
      throw WorkspaceLauncherError.emptyComposition
    }
    for step in request.steps {
      switch step {
      case .shell(let command, let waitsForExit):
        try runProcess(
          URL(fileURLWithPath: "/bin/zsh"), ["-c", command], waitsForExit)
      case .appleScript(let source):
        try runProcess(
          URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", source], true)
      case .openApplication(let applicationName):
        // Picker-created launchers retain the chosen bundle's path. If the app
        // moves, let Launch Services find it again by its saved identity.
        let arguments =
          applicationName.hasPrefix("/") && !request.bundleID.isEmpty
            && !FileManager.default.fileExists(atPath: applicationName)
          ? ["-b", request.bundleID] : ["-a", applicationName]
        try runProcess(URL(fileURLWithPath: "/usr/bin/open"), arguments, true)
      case .launchServices(let configuration):
        guard !request.bundleID.isEmpty else {
          throw WorkspaceLauncherError.missingLaunchServicesBundleID
        }
        var environment: [String: String] = [:]
        for variable in configuration.environment {
          let name = variable.name.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !name.isEmpty else { continue }
          environment[name] = variable.value
        }
        try openWithLaunchServices(
          WorkspaceLaunchServicesRequest(
            bundleID: request.bundleID,
            target: Self.launchServicesTarget(from: configuration.target),
            arguments: configuration.arguments.filter { !$0.isEmpty },
            environment: environment,
            createsNewApplicationInstance: configuration.createsNewApplicationInstance,
            activates: configuration.activates))
      }
    }
  }

  static func launchServicesTarget(from value: String) -> URL? {
    let target = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else { return nil }

    if let url = URL(string: target), url.scheme != nil {
      return url
    }

    let path = (target as NSString).expandingTildeInPath
    return URL(fileURLWithPath: path).standardizedFileURL
  }

  static func openConfiguration(
    for request: WorkspaceLaunchServicesRequest
  ) -> NSWorkspace.OpenConfiguration {
    let configuration = NSWorkspace.OpenConfiguration()
    if !request.arguments.isEmpty {
      configuration.arguments = request.arguments
    }
    if !request.environment.isEmpty {
      configuration.environment = request.environment
    }
    if request.createsNewApplicationInstance {
      configuration.createsNewApplicationInstance = true
    }
    configuration.activates = request.activates
    return configuration
  }

  private static func runProcess(
    executable: URL,
    arguments: [String],
    waitsForExit: Bool
  ) throws {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments

    guard waitsForExit else {
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      return
    }

    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = outputPipe
    try process.run()

    outputPipe.fileHandleForWriting.closeFile()
    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus != 0 else { return }

    let output = String(decoding: outputData, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let type: String
    switch executable.lastPathComponent {
    case "osascript": type = "applescript"
    case "zsh": type = "shell"
    default: type = "open"
    }
    throw WorkspaceLauncherError.processFailed(
      type: type,
      status: process.terminationStatus,
      output: output)
  }
}

private enum LaunchServicesWorkspaceOpener {
  static func open(_ request: WorkspaceLaunchServicesRequest) throws {
    let workspace = NSWorkspace.shared
    guard
      let applicationURL = workspace.urlForApplication(withBundleIdentifier: request.bundleID)
    else {
      throw WorkspaceLauncherError.applicationNotFound(request.bundleID)
    }

    let configuration = WorkspaceLauncherExecutor.openConfiguration(for: request)
    let completion = LaunchServicesCompletion()
    let semaphore = DispatchSemaphore(value: 0)
    let handler: @Sendable (NSRunningApplication?, Error?) -> Void = { application, error in
      completion.finish(application: application, error: error)
      semaphore.signal()
    }

    if let target = request.target {
      workspace.open(
        [target],
        withApplicationAt: applicationURL,
        configuration: configuration,
        completionHandler: handler)
    } else {
      workspace.openApplication(
        at: applicationURL,
        configuration: configuration,
        completionHandler: handler)
    }

    guard semaphore.wait(timeout: .now() + 30) == .success else {
      throw WorkspaceLauncherError.launchServicesTimedOut(request.bundleID)
    }
    if let error = completion.error {
      throw error
    }
    guard let application = completion.application else { return }
    awaitFinishedLaunching(pid: application.processIdentifier)
  }

  /// Later steps (AppleScript, GUI scripting) need a fully launched app, so
  /// wait — bounded — for `isFinishedLaunching`. An `NSRunningApplication`'s
  /// properties only refresh when the MAIN run loop turns, and the CLI
  /// restore blocks its main thread, so the instance from the completion
  /// handler would read `false` forever there; poll a fresh instance by pid
  /// instead. The launch itself already succeeded, so a slow starter that
  /// outlives the deadline is not an error — the next step simply runs.
  private static let readinessTimeout: TimeInterval = 5
  private static let readinessPollInterval: TimeInterval = 0.05

  private static func awaitFinishedLaunching(pid: pid_t) {
    let deadline = ProcessInfo.processInfo.systemUptime + readinessTimeout
    while ProcessInfo.processInfo.systemUptime < deadline {
      guard let fresh = NSRunningApplication(processIdentifier: pid) else { return }
      if fresh.isFinishedLaunching { return }
      Thread.sleep(forTimeInterval: readinessPollInterval)
    }
  }
}

enum WorkspaceLauncherError: Error, LocalizedError {
  case emptyComposition
  case missingLaunchServicesBundleID
  case applicationNotFound(String)
  case launchServicesTimedOut(String)
  case processFailed(type: String, status: Int32, output: String)

  var errorDescription: String? {
    switch self {
    case .emptyComposition:
      return "Workspace launcher has no configured steps"
    case .missingLaunchServicesBundleID:
      return "Launch Services launchers require a bundle ID"
    case .applicationNotFound(let bundleID):
      return "No application is installed for bundle ID \(bundleID)"
    case .launchServicesTimedOut(let bundleID):
      return "Launch Services timed out while opening \(bundleID)"
    case .processFailed(let type, let status, let output):
      let detail = output.isEmpty ? "no error output" : output
      return "\(type) launcher exited with status \(status): \(detail)"
    }
  }
}

private final class LaunchServicesCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var storedApplication: NSRunningApplication?
  private var storedError: Error?

  var application: NSRunningApplication? {
    lock.lock()
    defer { lock.unlock() }
    return storedApplication
  }

  var error: Error? {
    lock.lock()
    defer { lock.unlock() }
    return storedError
  }

  func finish(application: NSRunningApplication?, error: Error?) {
    lock.lock()
    storedApplication = application
    storedError = error
    lock.unlock()
  }
}
