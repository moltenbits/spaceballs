import Foundation

// MARK: - Launch Type

public enum LaunchType: String, Codable, CaseIterable, Identifiable {
  case shell
  case applescript
  case open

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .shell: "Shell command"
    case .applescript: "AppleScript"
    case .open: "Open application"
    }
  }
}

// MARK: - App Launcher

public struct AppLauncher: Codable, Equatable, Identifiable {
  public var id: UUID
  public var label: String
  public var type: LaunchType
  public var command: String
  /// The app name to look for in the window list (e.g. "Safari", "iTerm2").
  /// If set, the launcher is skipped when an app with this name already has
  /// a window in the target space. If empty, the launcher always runs.
  public var appName: String

  public init(
    id: UUID = UUID(),
    label: String = "",
    type: LaunchType = .shell,
    appName: String = "",
    command: String = ""
  ) {
    self.id = id
    self.label = label
    self.type = type
    self.appName = appName
    self.command = command
  }

  // Decode with backward compatibility for data saved before appName existed.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    label = try c.decode(String.self, forKey: .label)
    type = try c.decode(LaunchType.self, forKey: .type)
    command = try c.decode(String.self, forKey: .command)
    appName = try c.decodeIfPresent(String.self, forKey: .appName) ?? ""
  }

  private enum CodingKeys: String, CodingKey {
    case id, label, type, command, appName
  }

  /// Returns the command with workspace variables substituted.
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
    case .genericShell: "Shell Command"
    }
  }

  public var launcher: AppLauncher {
    switch self {
    case .iterm:
      return AppLauncher(
        label: "",
        type: .applescript,
        appName: "iTerm",
        command: """
          tell application "iTerm"
            set newWindow to (create window with default profile)
            tell current session of newWindow
              write text "cd $PATH"
            end tell
          end tell
          """
      )
    case .intellij:
      return AppLauncher(
        label: "",
        type: .shell,
        appName: "IntelliJ IDEA",
        command: "idea \"$PATH\""
      )
    case .tower:
      return AppLauncher(
        label: "",
        type: .shell,
        appName: "Tower",
        command: "gittower \"$PATH\""
      )
    case .safari:
      return AppLauncher(
        label: "",
        type: .applescript,
        appName: "Safari",
        command: """
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
      )
    case .safariProfile:
      return AppLauncher(
        label: "$NAME",
        type: .applescript,
        appName: "Safari",
        command: """
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
      )
    case .genericOpen:
      return AppLauncher(
        label: "App",
        type: .open,
        command: "AppName"
      )
    case .genericShell:
      return AppLauncher(
        label: "Command",
        type: .shell,
        command: "echo \"$PATH\""
      )
    }
  }
}
