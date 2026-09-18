import Foundation
import SpaceballsCore

// MARK: - Launch Type

public typealias LaunchType = WorkspaceLaunchType

extension WorkspaceLaunchType {
  public var label: String {
    switch self {
    case .shell: "Shell command"
    case .applescript: "AppleScript"
    case .open: "Open application"
    case .launchServices: "Launch Services"
    }
  }
}

// MARK: - App Launcher

public struct AppLauncher: Codable, Equatable, Identifiable {
  static let legacyITermCommand = """
    tell application "iTerm"
      set newWindow to (create window with default profile)
      tell current session of newWindow
        write text "cd $PATH"
      end tell
    end tell
    """

  static let shellLaunchingITermCommand = """
    do shell script "/usr/bin/open -g -b com.googlecode.iterm2"
    tell application "iTerm"
      set newWindow to (create window with default profile)
      tell current session of newWindow
        write text "cd $PATH"
      end tell
    end tell
    """

  static let iTermCommand = legacyITermCommand

  static let shellLaunchingSafariCommand = """
    tell application "System Events"
      if not (exists process "Safari") then
        do shell script "open -a Safari"
        delay 1
      end if
      tell process "Safari"
        click menu item "New Window" of menu 1 of menu bar item "File" of menu bar 1
      end tell
    end tell
    """

  static let safariCommand = """
    tell application "System Events"
      tell process "Safari"
        click menu item "New Window" of menu 1 of menu bar item "File" of menu bar 1
      end tell
    end tell
    """

  static let shellLaunchingSafariProfileCommand = """
    tell application "System Events"
      if not (exists process "Safari") then
        do shell script "open -a Safari"
        delay 1
      end if
      tell process "Safari"
        click menu item "New $PROFILE Window" of menu 1 of menu item "New Window" of menu 1 of menu bar item "File" of menu bar 1
      end tell
    end tell
    """

  static let safariProfileCommand = """
    tell application "System Events"
      tell process "Safari"
        click menu item "New $PROFILE Window" of menu 1 of menu item "New Window" of menu 1 of menu bar item "File" of menu bar 1
      end tell
    end tell
    """

  public var id: UUID
  public var label: String
  public var steps: [WorkspaceLauncherStep]
  /// The app name to look for in the window list (e.g. "Safari", "iTerm2").
  /// If set, the launcher is skipped when an app with this name already has
  /// a window in the target space. If empty, the launcher always runs.
  public var appName: String
  /// Stable application identity used to match saved window layouts.
  public var bundleID: String
  public var allowsExistingWindow: Bool

  /// Whether a window-matching app is associated with this launcher.
  public var hasApplication: Bool { !appName.isEmpty || !bundleID.isEmpty }

  /// A Launch Services step launches by the launcher's bundle ID, so it cannot run
  /// without an application. Every other pipeline may run unassociated: it always
  /// executes and skips window placement.
  public var applicationIsOptional: Bool {
    !steps.contains { if case .launchServices = $0.action { true } else { false } }
  }

  /// Point window matching, Launch Services steps, and the Open App steps that launch
  /// this launcher's app at the chosen application. Launch Services steps read the
  /// launcher's bundle ID at launch. A lone Open App step is retargeted outright;
  /// among several, only the ones launching the previous app change, so a pipeline
  /// that opens a helper app alongside keeps that step.
  public mutating func selectApplication(_ application: WorkspaceApplication) {
    let openSteps = steps.indices.filter {
      if case .openApplication = steps[$0].action { true } else { false }
    }
    let retargeted =
      openSteps.count == 1 ? openSteps : openSteps.filter { launchesCurrentApplication(steps[$0]) }
    appName = application.name
    bundleID = application.bundleID
    for index in retargeted {
      // A display name can differ from the bundle's filename, and several installed
      // apps can share a name. `open -a` also accepts the exact application path.
      steps[index].action = .openApplication(application.url.path)
    }
  }

  /// Drop the application association, leaving steps, IDs, and policy alone.
  public mutating func clearApplication() {
    appName = ""
    bundleID = ""
  }

  private func launchesCurrentApplication(_ step: WorkspaceLauncherStep) -> Bool {
    guard case .openApplication(let target) = step.action else { return false }
    if !appName.isEmpty, target == appName { return true }
    guard target.hasPrefix("/"), !bundleID.isEmpty,
      let opened = WorkspaceApplication(url: URL(fileURLWithPath: target))
    else { return false }
    return opened.bundleID == bundleID
  }

  public init(
    id: UUID = UUID(),
    label: String = "",
    appName: String = "",
    bundleID: String = "",
    allowsExistingWindow: Bool = true,
    steps: [WorkspaceLauncherStep]
  ) {
    self.id = id
    self.label = label
    self.appName = appName
    self.bundleID = bundleID
    self.allowsExistingWindow = allowsExistingWindow
    self.steps = steps
  }

  public init(
    id: UUID = UUID(),
    label: String = "",
    type: LaunchType = .shell,
    appName: String = "",
    bundleID: String = "",
    command: String = ""
  ) {
    self.init(
      id: id,
      label: label,
      appName: appName,
      bundleID: bundleID,
      allowsExistingWindow: type != .applescript,
      steps: [Self.step(type: type, command: command)])
  }

  // Decode both composed launchers and the legacy single type/command format.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    label = try c.decode(String.self, forKey: .label)
    appName = try c.decodeIfPresent(String.self, forKey: .appName) ?? ""
    bundleID =
      try c.decodeIfPresent(String.self, forKey: .bundleID)
      ?? Self.knownBundleID(forAppName: appName)
    if let decodedSteps = try c.decodeIfPresent([WorkspaceLauncherStep].self, forKey: .steps) {
      steps = decodedSteps
    } else {
      let legacyType = try c.decode(LaunchType.self, forKey: .type)
      let legacyCommand = try c.decode(String.self, forKey: .command)
      steps = Self.migratedSteps(
        command: legacyCommand, type: legacyType, bundleID: bundleID)
    }
    // Only old saved launchers infer policy from their former execution behavior.
    allowsExistingWindow =
      try c.decodeIfPresent(Bool.self, forKey: .allowsExistingWindow)
      ?? !steps.contains { $0.type == .applescript }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(label, forKey: .label)
    try c.encode(steps, forKey: .steps)
    try c.encode(appName, forKey: .appName)
    try c.encode(bundleID, forKey: .bundleID)
    try c.encode(allowsExistingWindow, forKey: .allowsExistingWindow)
  }

  private enum CodingKeys: String, CodingKey {
    case id, label, steps, type, command, appName, bundleID, allowsExistingWindow
  }

  private static func knownBundleID(forAppName appName: String) -> String {
    switch appName.lowercased() {
    case "iterm", "iterm2": "com.googlecode.iterm2"
    case "intellij idea": "com.jetbrains.intellij"
    case "tower": "com.fournova.Tower3"
    case "safari": "com.apple.Safari"
    default: ""
    }
  }

  private static func migratedSteps(
    command: String, type: LaunchType, bundleID: String
  ) -> [WorkspaceLauncherStep] {
    switch (type, bundleID, command) {
    case (.applescript, "com.googlecode.iterm2", legacyITermCommand),
      (.applescript, "com.googlecode.iterm2", shellLaunchingITermCommand):
      return composedSteps(script: iTermCommand)
    case (.applescript, "com.apple.Safari", shellLaunchingSafariCommand),
      (.applescript, "com.apple.Safari", safariCommand):
      return composedSteps(script: safariCommand)
    case (.applescript, "com.apple.Safari", shellLaunchingSafariProfileCommand),
      (.applescript, "com.apple.Safari", safariProfileCommand):
      return composedSteps(script: safariProfileCommand)
    case (.shell, "com.jetbrains.intellij", "idea \"$PATH\""):
      return [launchServicesStep(target: "$PATH")]
    case (.shell, "com.fournova.Tower3", "gittower \"$PATH\""):
      return [launchServicesStep(target: "$PATH")]
    default:
      return [step(type: type, command: command)]
    }
  }

  public var usesProfileVariable: Bool {
    steps.contains { step in
      switch step.action {
      case .shell(let command, _), .appleScript(let command), .openApplication(let command):
        return command.contains("$PROFILE") || command.contains("${PROFILE}")
      case .launchServices(let configuration):
        let values =
          [configuration.target] + configuration.arguments
          + configuration.environment.map(\.value)
        return values.contains {
          $0.contains("$PROFILE") || $0.contains("${PROFILE}")
        }
      }
    }
  }

  private static func composedSteps(script: String) -> [WorkspaceLauncherStep] {
    [
      launchServicesStep(activates: false),
      WorkspaceLauncherStep(action: .appleScript(script)),
    ]
  }

  private static func launchServicesStep(
    target: String = "", activates: Bool = true
  ) -> WorkspaceLauncherStep {
    WorkspaceLauncherStep(
      action: .launchServices(
        WorkspaceLaunchServicesConfiguration(target: target, activates: activates)))
  }

  private static func step(type: LaunchType, command: String) -> WorkspaceLauncherStep {
    WorkspaceLauncherStep(
      action: type == .shell
        ? .shell(command, waitsForExit: false)
        : WorkspaceLauncherAction(type: type, value: command))
  }
}

// MARK: - Workspace Config

public struct WorkspaceConfig: Codable, Equatable, Identifiable {
  public var id: UUID
  public var name: String
  public var path: String?
  public var launchers: [AppLauncher]

  public init(
    id: UUID = UUID(),
    name: String = "",
    path: String? = nil,
    launchers: [AppLauncher] = []
  ) {
    self.id = id
    self.name = name
    self.path = path
    self.launchers = launchers
  }

  // Backward-compatible decoder — new fields default gracefully
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    path = try c.decodeIfPresent(String.self, forKey: .path)
    launchers = try c.decodeIfPresent([AppLauncher].self, forKey: .launchers) ?? []
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, path, launchers
  }
}

// MARK: - Launcher Templates

public enum LauncherTemplate: String, CaseIterable, Identifiable {
  case iterm
  case intellij
  case tower
  case safari
  case safariProfile
  case genericOpen
  case genericLaunchServices
  case genericAppleScript
  case genericShell

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .iterm: "iTerm"
    case .intellij: "IntelliJ IDEA"
    case .tower: "Tower (Git)"
    case .safari: "Safari"
    case .safariProfile: "Safari (Profile)"
    case .genericOpen: "Open App"
    case .genericLaunchServices: "Launch Services"
    case .genericAppleScript: "AppleScript"
    case .genericShell: "Shell Command"
    }
  }

  public var launcher: AppLauncher {
    switch self {
    case .iterm:
      return AppLauncher(
        label: "",
        appName: "iTerm",
        bundleID: "com.googlecode.iterm2",
        allowsExistingWindow: false,
        steps: [
          WorkspaceLauncherStep(
            action: .launchServices(
              WorkspaceLaunchServicesConfiguration(activates: false))),
          WorkspaceLauncherStep(action: .appleScript(AppLauncher.iTermCommand)),
        ]
      )
    case .intellij:
      return AppLauncher(
        label: "",
        appName: "IntelliJ IDEA",
        bundleID: "com.jetbrains.intellij",
        steps: [
          WorkspaceLauncherStep(
            action: .launchServices(
              WorkspaceLaunchServicesConfiguration(target: "$PATH", activates: true)))
        ]
      )
    case .tower:
      return AppLauncher(
        label: "",
        appName: "Tower",
        bundleID: "com.fournova.Tower3",
        steps: [
          WorkspaceLauncherStep(
            action: .launchServices(
              WorkspaceLaunchServicesConfiguration(target: "$PATH", activates: true)))
        ]
      )
    case .safari:
      return AppLauncher(
        label: "",
        appName: "Safari",
        bundleID: "com.apple.Safari",
        allowsExistingWindow: false,
        steps: [
          WorkspaceLauncherStep(
            action: .launchServices(
              WorkspaceLaunchServicesConfiguration(activates: false))),
          WorkspaceLauncherStep(action: .appleScript(AppLauncher.safariCommand)),
        ]
      )
    case .safariProfile:
      return AppLauncher(
        label: "$NAME",
        appName: "Safari",
        bundleID: "com.apple.Safari",
        allowsExistingWindow: false,
        steps: [
          WorkspaceLauncherStep(
            action: .launchServices(
              WorkspaceLaunchServicesConfiguration(activates: false))),
          WorkspaceLauncherStep(action: .appleScript(AppLauncher.safariProfileCommand)),
        ]
      )
    case .genericOpen:
      return AppLauncher(
        label: "App",
        steps: [WorkspaceLauncherStep(action: .openApplication("AppName"))]
      )
    case .genericLaunchServices:
      return AppLauncher(
        label: "App",
        steps: [
          WorkspaceLauncherStep(
            action: .launchServices(
              WorkspaceLaunchServicesConfiguration(target: "$PATH", activates: true)))
        ]
      )
    case .genericAppleScript:
      return AppLauncher(
        label: "Script",
        steps: [
          WorkspaceLauncherStep(action: .appleScript("-- Enter AppleScript here"))
        ]
      )
    case .genericShell:
      return AppLauncher(
        label: "Command",
        steps: [WorkspaceLauncherStep(action: .shell("echo \"$PATH\""))]
      )
    }
  }
}
