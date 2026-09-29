import AppKit
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

/// System operations used by `WorkspaceRestorer`. Keeping the orchestration
/// behind narrow closures makes launch/restore ordering deterministic in tests.
enum WorkspaceLauncherPlacement: Equatable {
  case waiting
  case onTarget
  case relocated
}

struct WorkspaceLauncherWindow: Equatable {
  let id: Int
  let spaceIDs: [UInt64]
}

struct WorkspaceRestorerHooks {
  var createDefaultSpaces: ([String], SpaceNameStoring) throws -> Int
  var allSpaces: () -> [SpaceInfo]
  var windowsBySpace: () -> [UInt64: [WindowInfo]]
  var launcherWindows: (String) -> [WorkspaceLauncherWindow] = { _ in [] }
  var switchToSpace: (UInt64) throws -> Void
  var focusDisplay: (UInt64) throws -> Void
  var executeLauncher: (WorkspaceLaunchRequest) throws -> Void
  var relocateFocusedWindow: (String, UInt64, Set<Int>, Bool) throws -> WorkspaceLauncherPlacement
  var bundleIDForPID: (Int) -> String? = { _ in nil }
  var relocateWindow: (Int, UInt64) throws -> Bool = { _, _ in false }
  var sleep: (TimeInterval) -> Void
  var diagnosticsEnabled: () -> Bool = { Diagnostics.enabled }
  var frontmostApplication: () -> String = { "unknown" }
  var logDiagnostic: (String) -> Void = { Diagnostics.log("workspace-restore", $0) }
}

/// Orchestrates workspace restoration: creates spaces, switches to each,
/// and launches configured apps. Shared between CLI and GUI.
public final class WorkspaceRestorer {
  private let spaceNameStore: SpaceNameStoring
  private let windowLayoutRestorer: WorkspaceWindowLayoutRestorer?
  private let hooks: WorkspaceRestorerHooks

  public convenience init(
    spaceManager: SpaceManager,
    spaceNameStore: SpaceNameStoring,
    windowLayoutRestorer: WorkspaceWindowLayoutRestorer? = nil
  ) {
    let hooks = WorkspaceRestorerHooks(
      createDefaultSpaces: { names, store in
        try spaceManager.createDefaultSpacesSync(
          defaultNames: names, spaceNameStore: store)
      },
      allSpaces: { spaceManager.getAllSpaces() },
      windowsBySpace: { spaceManager.windowsBySpace().1 },
      launcherWindows: { bundleID in
        Self.accessibilityWindows(bundleID: bundleID, spaceManager: spaceManager)
      },
      switchToSpace: { try spaceManager.switchToSpace(id: $0) },
      focusDisplay: { try spaceManager.focusDisplayForWorkspace(spaceID: $0) },
      executeLauncher: { try WorkspaceLauncherExecutor.live.execute($0) },
      relocateFocusedWindow: {
        bundleID, targetSpaceID, preexistingWindowIDs, allowsExistingWindow in
        try Self.relocateFocusedWindow(
          bundleID: bundleID,
          targetSpaceID: targetSpaceID,
          preexistingWindowIDs: preexistingWindowIDs,
          allowsExistingWindow: allowsExistingWindow,
          spaceManager: spaceManager)
      },
      bundleIDForPID: { pid in
        ProcessBundleIdentifierResolver.resolve(pid: pid)
      },
      relocateWindow: { windowID, targetSpaceID in
        try spaceManager.moveWindowToSpace(
          windowID: windowID,
          targetSpaceID: targetSpaceID,
          activateAfterMove: false)
      },
      sleep: { Thread.sleep(forTimeInterval: $0) },
      frontmostApplication: {
        guard let app = NSWorkspace.shared.frontmostApplication else { return "none" }
        return "\(app.bundleIdentifier ?? "unknown") pid=\(app.processIdentifier)"
      })
    self.init(
      spaceNameStore: spaceNameStore,
      windowLayoutRestorer: windowLayoutRestorer,
      hooks: hooks)
  }

  init(
    spaceNameStore: SpaceNameStoring,
    windowLayoutRestorer: WorkspaceWindowLayoutRestorer?,
    hooks: WorkspaceRestorerHooks
  ) {
    self.spaceNameStore = spaceNameStore
    self.windowLayoutRestorer = windowLayoutRestorer
    self.hooks = hooks
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
    let initialSpaces = hooks.allSpaces()
    let missingNames = defaultNames.filter {
      spaceNameStore.spaceWithCustomName($0, in: initialSpaces) == nil
    }
    let spacesCreated =
      missingNames.isEmpty ? 0 : try hooks.createDefaultSpaces(missingNames, spaceNameStore)

    // Brief pause if spaces were created
    if spacesCreated > 0 {
      hooks.sleep(1.0)
    }

    // 2. Activate each workspace, including ones whose apps are already present.
    var appsLaunched = 0
    var errors: [(String, String, String)] = []
    // Every recorded error also reaches the diagnostics log (the summary shown on
    // screen only counts them), but the log gets the payload-free description.
    func recordError(_ workspaceName: String, _ app: String, _ summary: String, log: String) {
      errors.append((workspaceName, app, summary))
      guard hooks.diagnosticsEnabled() else { return }
      hooks.logDiagnostic(
        "error workspace=\"\(workspaceName)\"\(app.isEmpty ? "" : " app=\"\(app)\"") \(log)")
    }
    func recordError(_ workspaceName: String, _ app: String, _ prefix: String, _ error: Error) {
      recordError(
        workspaceName, app, prefix + error.localizedDescription,
        log: prefix + Self.diagnosticDescription(of: error))
    }

    for (i, workspace) in workspaces.enumerated() {
      progress?(i, workspaces.count, workspace.name)

      // Resolve space name to ID
      let spaces = hooks.allSpaces()
      guard let targetSpace = spaceNameStore.spaceWithCustomName(workspace.name, in: spaces) else {
        recordError(workspace.name, "", "Space not found", log: "Space not found")
        continue
      }
      let spaceID = targetSpace.id

      // Check which apps are already running in this space
      let windowMap = hooks.windowsBySpace()
      let existingWindows = (windowMap[spaceID] ?? []).map {
        (appName: $0.ownerName, bundleID: hooks.bundleIDForPID($0.pid))
      }

      // Filter to only launchers whose app isn't already in the space
      let missingLaunchers = workspace.launchers.filter { launcher in
        !existingWindows.contains { window in
          if !launcher.bundleID.isEmpty, let bundleID = window.bundleID, !bundleID.isEmpty {
            return bundleID == launcher.bundleID
          }
          // Legacy launchers and unresolvable processes retain name-based matching.
          return !launcher.appName.isEmpty && window.appName == launcher.appName
        }
      }

      // Associate before launching so future Spaceballs resizes update the
      // stable workspace layout even when no prior workspace layout exists.
      let hasWorkspaceLayout =
        windowLayoutRestorer?.prepare(
          workspaceID: workspace.id,
          spaceUUID: targetSpace.uuid,
          displayUUID: targetSpace.displayUUID,
          bundleIDs: Set(workspace.launchers.map(\.bundleID).filter { !$0.isEmpty })) ?? false

      // Switch to the space and ensure it has keyboard focus.
      // On multi-display, establish focus on the target display without
      // blindly clicking through whichever app happens to cover its center.
      do {
        try focusTargetSpace(
          spaceID, forceSwitch: true, context: "workspace=\(workspace.id) initial")
      } catch {
        recordError(workspace.name, "", "Failed to switch: ", error)
        continue
      }

      // Launch only missing apps
      var focusFailed = false
      for (launcherIndex, launcher) in missingLaunchers.enumerated() {
        var preexistingWindowIDs = Set(
          hooks.windowsBySpace().values.flatMap { $0 }.map(\.id))
        if !launcher.bundleID.isEmpty {
          preexistingWindowIDs.formUnion(
            hooks.launcherWindows(launcher.bundleID).map(\.id))
        }
        let request = launcher.resolvedLaunchRequest(
          path: workspace.path, name: workspace.name)
        let context = launcherDiagnosticContext(
          workspace: workspace, launcher: launcher, index: launcherIndex)
        do {
          if !hooks.allSpaces().contains(where: { $0.id == spaceID && $0.isCurrent }) {
            try focusTargetSpace(spaceID, forceSwitch: false, context: context)
          }
          logState("before-launch", targetSpaceID: spaceID, context: context)
          try hooks.executeLauncher(request)
          logState("after-execute", targetSpaceID: spaceID, context: context)
          appsLaunched += 1
          if launcher.bundleID.isEmpty {
            hooks.sleep(1.0)
          } else {
            try waitForLaunchedWindowPlacement(
              bundleID: launcher.bundleID,
              targetSpaceID: spaceID,
              preexistingWindowIDs: preexistingWindowIDs,
              allowsExistingWindow: launcher.allowsExistingWindow)
          }
          logState("after-placement", targetSpaceID: spaceID, context: context)
        } catch {
          logState("launcher-failed", targetSpaceID: spaceID, context: context)
          recordError(
            workspace.name,
            launcher.appName.isEmpty
              ? launcher.steps.first?.type.rawValue ?? "launcher" : launcher.appName,
            "", error)
        }

        guard launcherIndex < missingLaunchers.count - 1 else { continue }
        do {
          try focusTargetSpace(spaceID, forceSwitch: false, context: context)
        } catch {
          recordError(workspace.name, "", "Failed to refocus: ", error)
          focusFailed = true
          break
        }
      }
      if focusFailed { continue }

      // Launching or activating an already-running app can switch macOS back
      // to that app's existing Space. Return to the workspace before applying
      // its layout, even after the final launcher.
      if let lastLauncher = missingLaunchers.last {
        do {
          try focusTargetSpace(
            spaceID, forceSwitch: false,
            context: launcherDiagnosticContext(
              workspace: workspace, launcher: lastLauncher,
              index: missingLaunchers.count - 1))
        } catch {
          recordError(workspace.name, "", "Failed to refocus: ", error)
          continue
        }
      }

      if hasWorkspaceLayout {
        _ = windowLayoutRestorer?.restoreWhenReady(
          workspaceID: workspace.id,
          spaceUUID: targetSpace.uuid,
          displayUUID: targetSpace.displayUUID)
      }
    }

    progress?(workspaces.count, workspaces.count, "Done")

    return RestoreSummary(
      spacesCreated: spacesCreated,
      appsLaunched: appsLaunched,
      errors: errors
    )
  }

  private func launcherDiagnosticContext(
    workspace: WorkspaceConfigData, launcher: LauncherData, index: Int
  ) -> String {
    let steps = launcher.steps.map { step in
      if case .launchServices(let configuration) = step.action {
        return "launchServices(activates=\(configuration.activates))"
      }
      return step.type.rawValue
    }.joined(separator: ",")
    // IDs and step types only: do not expose commands, paths, arguments, or environment values.
    return
      "workspace=\(workspace.id) launcher=\(index + 1) app=\(launcher.bundleID.isEmpty ? "unknown" : launcher.bundleID) steps=[\(steps)]"
  }

  /// What the diagnostics log may say about an error: launcher failures drop
  /// their process output, restorer failures name only IDs, and anything else is
  /// reduced to its domain and code.
  static func diagnosticDescription(of error: Error) -> String {
    switch error {
    case let error as WorkspaceLauncherError: return error.diagnosticDescription
    case let error as WorkspaceRestorerError: return error.errorDescription ?? "\(error)"
    default:
      let error = error as NSError
      return "\(error.domain) code=\(error.code)"
    }
  }

  private func logState(_ phase: String, targetSpaceID: UInt64, context: String) {
    guard hooks.diagnosticsEnabled() else { return }
    let current = hooks.allSpaces().filter(\.isCurrent).map {
      "\($0.id)@\($0.displayUUID)"
    }.sorted().joined(separator: ",")
    hooks.logDiagnostic(
      "phase=\(phase) \(context) targetSpace=\(targetSpaceID) currentSpaces=[\(current)] frontmost=\(hooks.frontmostApplication())"
    )
  }

  private func focusTargetSpace(_ spaceID: UInt64, forceSwitch: Bool, context: String) throws {
    for attempt in 0..<3 {
      logState("before-refocus", targetSpaceID: spaceID, context: context)
      let isCurrent = hooks.allSpaces().contains { $0.id == spaceID && $0.isCurrent }
      if (forceSwitch && attempt == 0) || !isCurrent {
        if !forceSwitch {
          Diagnostics.log(
            "workspace-restore", "launcher changed active Space; refocusing space=\(spaceID)")
        }
        try hooks.switchToSpace(spaceID)
        hooks.sleep(2.0)  // Let focus and any fallback transition settle
      }
      logState("before-display-focus", targetSpaceID: spaceID, context: context)
      try hooks.focusDisplay(spaceID)
      hooks.sleep(0.5)
      logState("after-display-focus", targetSpaceID: spaceID, context: context)
      if hooks.allSpaces().contains(where: { $0.id == spaceID && $0.isCurrent }) { return }
    }
    throw WorkspaceRestorerError.targetSpaceFocusFailed(spaceID: spaceID)
  }

  private func waitForLaunchedWindowPlacement(
    bundleID: String,
    targetSpaceID: UInt64,
    preexistingWindowIDs: Set<Int>,
    allowsExistingWindow: Bool
  ) throws {
    let maximumAttempts = 12
    for attempt in 0..<maximumAttempts {
      var newWindows = hooks.launcherWindows(bundleID).filter {
        !preexistingWindowIDs.contains($0.id)
      }
      let inventoryWindows = Self.newLauncherWindows(
        in: hooks.windowsBySpace(),
        bundleID: bundleID,
        preexistingWindowIDs: preexistingWindowIDs,
        bundleIDForPID: hooks.bundleIDForPID
      )
      .map { WorkspaceLauncherWindow(id: $0.id, spaceIDs: $0.spaceIDs) }
      let accessibilityWindowIDs = Set(newWindows.map(\.id))
      newWindows.append(
        contentsOf: inventoryWindows.filter {
          !accessibilityWindowIDs.contains($0.id)
        })
      newWindows.sort { $0.id < $1.id }
      if !newWindows.isEmpty {
        for window in newWindows where !window.spaceIDs.contains(targetSpaceID) {
          Diagnostics.log(
            "workspace-restore",
            "relocating discovered launcher window=\(window.id) to space=\(targetSpaceID)",
            app: bundleID)
          let moved = try hooks.relocateWindow(window.id, targetSpaceID)
          guard moved else {
            throw WorkspaceRestorerError.windowRelocationFailed(
              windowID: window.id, targetSpaceID: targetSpaceID)
          }
        }
        return
      }

      switch try hooks.relocateFocusedWindow(
        bundleID, targetSpaceID, preexistingWindowIDs, allowsExistingWindow)
      {
      case .onTarget, .relocated:
        return
      case .waiting:
        if attempt < maximumAttempts - 1 {
          hooks.sleep(0.25)
        }
      }
    }
    Diagnostics.log(
      "workspace-restore",
      "launcher window placement unresolved after \(maximumAttempts) attempts",
      app: bundleID)
  }

  static func newLauncherWindows(
    in windowsBySpace: [UInt64: [WindowInfo]],
    bundleID: String,
    preexistingWindowIDs: Set<Int>,
    bundleIDForPID: (Int) -> String?
  ) -> [WindowInfo] {
    var windowsByID: [Int: WindowInfo] = [:]
    for window in windowsBySpace.values.joined()
    where !preexistingWindowIDs.contains(window.id)
      && bundleIDForPID(window.pid) == bundleID
    {
      windowsByID[window.id] = window
    }
    return windowsByID.values.sorted { $0.id < $1.id }
  }

  private static func accessibilityWindows(
    bundleID: String,
    spaceManager: SpaceManager
  ) -> [WorkspaceLauncherWindow] {
    var windowsByID: [Int: WorkspaceLauncherWindow] = [:]

    for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
      let appElement = AXUIElementCreateApplication(app.processIdentifier)
      var windowsRef: CFTypeRef?
      guard
        AXUIElementCopyAttributeValue(
          appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
        let windows = windowsRef as? [AXUIElement]
      else { continue }

      for window in windows {
        var windowID: CGWindowID = 0
        guard _AXUIElementGetWindow(window, &windowID) == .success else { continue }
        let id = Int(windowID)
        windowsByID[id] = WorkspaceLauncherWindow(
          id: id,
          spaceIDs: spaceManager.spaceIDs(forWindowID: id))
      }
    }

    return windowsByID.values.sorted { $0.id < $1.id }
  }

  private static func relocateFocusedWindow(
    bundleID: String,
    targetSpaceID: UInt64,
    preexistingWindowIDs: Set<Int>,
    allowsExistingWindow: Bool,
    spaceManager: SpaceManager
  ) throws -> WorkspaceLauncherPlacement {
    guard let focused = WindowResizer.focusedWindowID() else {
      Diagnostics.log(
        "workspace-restore", "launcher has no resolvable focused window", app: bundleID)
      return .waiting
    }
    let focusedBundleID = ProcessBundleIdentifierResolver.resolve(pid: Int(focused.pid)) ?? ""
    guard focusedBundleID == bundleID else {
      Diagnostics.log(
        "workspace-restore",
        "launcher focus belongs to \(focusedBundleID.isEmpty ? "unknown app" : focusedBundleID)",
        app: bundleID)
      return .waiting
    }

    let windowID = Int(focused.windowID)
    guard
      canRelocateLaunchedWindow(
        windowID: windowID,
        preexistingWindowIDs: preexistingWindowIDs,
        allowsExistingWindow: allowsExistingWindow)
    else {
      Diagnostics.log(
        "workspace-restore",
        "waiting for a new launcher window; focused window=\(windowID) predates launch",
        app: bundleID)
      return .waiting
    }
    guard !spaceManager.spaceIDs(forWindowID: windowID).contains(targetSpaceID) else {
      return .onTarget
    }
    Diagnostics.log(
      "workspace-restore",
      "relocating focused launcher window=\(windowID) to space=\(targetSpaceID)",
      app: bundleID)
    let moved = try spaceManager.moveWindowToSpace(
      windowID: windowID,
      targetSpaceID: targetSpaceID,
      activateAfterMove: false)
    guard moved else {
      throw WorkspaceRestorerError.windowRelocationFailed(
        windowID: windowID, targetSpaceID: targetSpaceID)
    }
    return .relocated
  }

  static func canRelocateLaunchedWindow(
    windowID: Int,
    preexistingWindowIDs: Set<Int>,
    allowsExistingWindow: Bool
  ) -> Bool {
    allowsExistingWindow || !preexistingWindowIDs.contains(windowID)
  }

}

/// Lightweight data transfer struct so WorkspaceRestorer doesn't depend on
/// SpaceballsGUILib's WorkspaceConfig (which lives in a different module).
public struct WorkspaceConfigData {
  public let id: String
  public let name: String
  public let path: String?
  public let launchers: [LauncherData]

  public init(id: String, name: String, path: String?, launchers: [LauncherData]) {
    self.id = id
    self.name = name
    self.path = path
    self.launchers = launchers
  }
}

public struct LauncherData {
  public let label: String
  public let steps: [WorkspaceLauncherStep]
  public let appName: String
  public let bundleID: String
  public let allowsExistingWindow: Bool

  public init(
    label: String,
    steps: [WorkspaceLauncherStep],
    appName: String = "",
    bundleID: String = "",
    allowsExistingWindow: Bool = true
  ) {
    self.label = label
    self.steps = steps
    self.appName = appName
    self.bundleID = bundleID
    self.allowsExistingWindow = allowsExistingWindow
  }

  public init(
    label: String,
    type: WorkspaceLaunchType,
    command: String,
    appName: String = "",
    bundleID: String = ""
  ) {
    self.init(
      label: label,
      steps: [
        WorkspaceLauncherStep(
          action: type == .shell
            ? .shell(command, waitsForExit: false)
            : WorkspaceLauncherAction(type: type, value: command))
      ],
      appName: appName,
      bundleID: bundleID,
      allowsExistingWindow: type != .applescript)
  }

  private static func expandedPath(_ path: String?) -> String {
    (path as NSString?)?.expandingTildeInPath ?? ""
  }

  private func resolvedValue(_ value: String, path: String?, name: String) -> String {
    var resolved = value
    let expandedPath = Self.expandedPath(path)
    var resolvedProfile = label.isEmpty ? name : label
    resolvedProfile = resolvedProfile.replacingOccurrences(of: "$PATH", with: expandedPath)
    resolvedProfile = resolvedProfile.replacingOccurrences(of: "${PATH}", with: expandedPath)
    resolvedProfile = resolvedProfile.replacingOccurrences(of: "$NAME", with: name)
    resolvedProfile = resolvedProfile.replacingOccurrences(of: "${NAME}", with: name)
    resolved = resolved.replacingOccurrences(of: "$PATH", with: expandedPath)
    resolved = resolved.replacingOccurrences(of: "${PATH}", with: expandedPath)
    resolved = resolved.replacingOccurrences(of: "$NAME", with: name)
    resolved = resolved.replacingOccurrences(of: "${NAME}", with: name)
    resolved = resolved.replacingOccurrences(of: "$PROFILE", with: resolvedProfile)
    resolved = resolved.replacingOccurrences(of: "${PROFILE}", with: resolvedProfile)
    resolved = resolved.replacingOccurrences(of: "$LABEL", with: resolvedProfile)
    resolved = resolved.replacingOccurrences(of: "${LABEL}", with: resolvedProfile)
    return resolved
  }

  func resolvedLaunchRequest(path: String?, name: String) -> WorkspaceLaunchRequest {
    WorkspaceLaunchRequest(
      steps: steps.map { step in
        switch step.action {
        case .shell(let command, let waitsForExit):
          return .shell(resolvedValue(command, path: path, name: name), waitsForExit: waitsForExit)
        case .appleScript(let source):
          return .appleScript(resolvedValue(source, path: path, name: name))
        case .openApplication(let applicationName):
          return .openApplication(resolvedValue(applicationName, path: path, name: name))
        case .launchServices(let configuration):
          return .launchServices(
            WorkspaceLaunchServicesConfiguration(
              target: resolvedValue(configuration.target, path: path, name: name),
              arguments: configuration.arguments.map {
                resolvedValue($0, path: path, name: name)
              },
              environment: configuration.environment.map {
                WorkspaceEnvironmentVariable(
                  id: $0.id,
                  name: $0.name,
                  value: resolvedValue($0.value, path: path, name: name))
              },
              createsNewApplicationInstance: configuration.createsNewApplicationInstance,
              activates: configuration.activates))
        }
      },
      bundleID: bundleID,
      workspacePath: Self.expandedPath(path))
  }
}

public enum WorkspaceRestorerError: Error, LocalizedError {
  case targetSpaceFocusFailed(spaceID: UInt64)
  case windowRelocationFailed(windowID: Int, targetSpaceID: UInt64)

  public var errorDescription: String? {
    switch self {
    case .targetSpaceFocusFailed(let spaceID):
      return "Could not safely focus workspace Space \(spaceID)"
    case .windowRelocationFailed(let windowID, let targetSpaceID):
      return "Failed to move window \(windowID) to Space \(targetSpaceID)"
    }
  }
}
