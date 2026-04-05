import Foundation

/// Result of a workspace restoration operation.
public struct RestoreSummary {
  public let spacesCreated: Int
  public let appsLaunched: Int
  public let errors: [(workspace: String, launcher: String, error: String)]

  public init(spacesCreated: Int, appsLaunched: Int, errors: [(String, String, String)]) {
    self.spacesCreated = spacesCreated
    self.appsLaunched = appsLaunched
    self.errors = errors
  }
}

/// Orchestrates workspace restoration: creates spaces, switches to each,
/// and launches configured apps. Shared between CLI and GUI.
public final class WorkspaceRestorer {
  private let spaceManager: SpaceManager
  private let spaceNameStore: SpaceNameStoring

  public init(spaceManager: SpaceManager, spaceNameStore: SpaceNameStoring) {
    self.spaceManager = spaceManager
    self.spaceNameStore = spaceNameStore
  }

  /// Synchronously restores workspaces: creates missing spaces, switches to
  /// each one, and launches its configured apps.
  ///
  /// - Parameters:
  ///   - workspaces: Workspace configs to restore.
  ///   - defaultNames: All workspace names (for createDefaultSpaces).
  ///   - progress: Optional callback after each workspace (completed, total, name).
  /// - Returns: Summary of what was done.
  public func restoreSync(
    workspaces: [WorkspaceConfigData],
    defaultNames: [String],
    progress: ((Int, Int, String) -> Void)? = nil
  ) throws -> RestoreSummary {
    // 1. Create any missing spaces
    let spacesCreated = try spaceManager.createDefaultSpacesSync(
      defaultNames: defaultNames, spaceNameStore: spaceNameStore)

    // Brief pause if spaces were created
    if spacesCreated > 0 {
      Thread.sleep(forTimeInterval: 1.0)
    }

    // 2. Restore each workspace that has launchers
    let workspacesWithLaunchers = workspaces.filter { !$0.launchers.isEmpty }
    var appsLaunched = 0
    var errors: [(String, String, String)] = []

    for (i, workspace) in workspacesWithLaunchers.enumerated() {
      progress?(i, workspacesWithLaunchers.count, workspace.name)

      // Resolve space name to ID
      let spaces = spaceManager.getAllSpaces()
      guard let spaceID = spaceNameStore.resolveSpaceID(workspace.name, spaces: spaces) else {
        errors.append((workspace.name, "", "Space not found"))
        continue
      }

      // Check which apps are already running in this space
      let (_, windowMap) = spaceManager.windowsBySpace()
      let existingApps = Set(
        (windowMap[spaceID] ?? []).map(\.ownerName)
      )

      // Filter to only launchers whose app isn't already in the space
      let missingLaunchers = workspace.launchers.filter { launcher in
        if launcher.appName.isEmpty { return true }  // No app name → always run
        return !existingApps.contains(launcher.appName)
      }

      // Skip this space entirely if all apps are present
      guard !missingLaunchers.isEmpty else { continue }

      // Switch to the space
      do {
        try spaceManager.switchToSpace(id: spaceID)
        Thread.sleep(forTimeInterval: 2.0)  // Wait for space switch animation
      } catch {
        errors.append((workspace.name, "", "Failed to switch: \(error.localizedDescription)"))
        continue
      }

      // Launch only missing apps
      for launcher in missingLaunchers {
        let resolved = launcher.resolvedCommand(path: workspace.path, name: workspace.name)
        do {
          try executeLauncher(type: launcher.type, command: resolved)
          appsLaunched += 1
          Thread.sleep(forTimeInterval: 1.0)
        } catch {
          errors.append(
            (workspace.name, launcher.appName.isEmpty ? launcher.type : launcher.appName,
              error.localizedDescription))
        }
      }
    }

    progress?(workspacesWithLaunchers.count, workspacesWithLaunchers.count, "Done")

    return RestoreSummary(
      spacesCreated: spacesCreated,
      appsLaunched: appsLaunched,
      errors: errors
    )
  }

  private func executeLauncher(type: String, command: String) throws {
    let process = Process()
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    switch type {
    case "shell":
      process.executableURL = URL(fileURLWithPath: "/bin/zsh")
      process.arguments = ["-c", command]
    case "applescript":
      process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
      process.arguments = ["-e", command]
    case "open":
      process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      process.arguments = ["-a", command]
    default:
      throw WorkspaceRestorerError.unknownLaunchType(type)
    }

    try process.run()
    // Don't wait for completion — apps should stay running
  }
}

/// Lightweight data transfer struct so WorkspaceRestorer doesn't depend on
/// SpaceballsGUILib's WorkspaceConfig (which lives in a different module).
public struct WorkspaceConfigData {
  public let name: String
  public let path: String?
  public let launchers: [LauncherData]

  public init(name: String, path: String?, launchers: [LauncherData]) {
    self.name = name
    self.path = path
    self.launchers = launchers
  }
}

public struct LauncherData {
  public let label: String
  public let type: String  // "shell", "applescript", "open"
  public let command: String
  public let appName: String

  public init(label: String, type: String, command: String, appName: String = "") {
    self.label = label
    self.type = type
    self.command = command
    self.appName = appName
  }

  public func resolvedCommand(path: String?, name: String) -> String {
    var cmd = command
    let expandedPath = (path as NSString?)?.expandingTildeInPath ?? ""
    let resolvedProfile = label.isEmpty ? name : label
    cmd = cmd.replacingOccurrences(of: "$PATH", with: expandedPath)
    cmd = cmd.replacingOccurrences(of: "${PATH}", with: expandedPath)
    cmd = cmd.replacingOccurrences(of: "$NAME", with: name)
    cmd = cmd.replacingOccurrences(of: "${NAME}", with: name)
    cmd = cmd.replacingOccurrences(of: "$PROFILE", with: resolvedProfile)
    cmd = cmd.replacingOccurrences(of: "${LABEL}", with: resolvedProfile)
    return cmd
  }
}

public enum WorkspaceRestorerError: Error, LocalizedError {
  case unknownLaunchType(String)

  public var errorDescription: String? {
    switch self {
    case .unknownLaunchType(let type):
      return "Unknown launch type: \(type)"
    }
  }
}
