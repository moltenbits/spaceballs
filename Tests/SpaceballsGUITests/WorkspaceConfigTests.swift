import Foundation
import Testing

@testable import SpaceballsCore
@testable import SpaceballsGUILib

@Suite("Workspace Launcher Bundle IDs")
struct WorkspaceConfigTests {
  @Test("Legacy composed shell steps retain background behavior")
  func legacyShellPolicy() throws {
    let data = Data(#"{"type":"shell","command":"serve"}"#.utf8)
    let action = try JSONDecoder().decode(WorkspaceLauncherAction.self, from: data)
    #expect(action == .shell("serve", waitsForExit: false))
  }

  @Test("Launcher and shell policies round-trip and survive duplication", arguments: [true, false])
  func executionPoliciesRoundTrip(policy: Bool) throws {
    let original = AppLauncher(
      allowsExistingWindow: policy,
      steps: [WorkspaceLauncherStep(action: .shell("serve", waitsForExit: policy))])
    let decoded = try JSONDecoder().decode(AppLauncher.self, from: JSONEncoder().encode(original))
    #expect(decoded == original)
    #expect(decoded.steps[0].duplicated().action == original.steps[0].action)
  }

  @Test("Adding AppleScript does not change an existing launcher's window policy")
  func addingScriptPreservesReuse() {
    var launcher = LauncherTemplate.intellij.launcher
    launcher.steps.append(WorkspaceLauncherStep(action: .appleScript("return 1")))
    #expect(launcher.allowsExistingWindow)
    for template in [LauncherTemplate.iterm, .tower, .safari, .safariProfile] {
      #expect(!template.launcher.allowsExistingWindow)
    }
    #expect(LauncherTemplate.genericShell.launcher.steps[0].action == .shell("echo \"$PATH\""))
  }

  @Test("Legacy window policy is inferred once and then persisted")
  func legacyWindowPolicy() throws {
    for type in [LaunchType.applescript, .shell, .open] {
      let launcher = try decodeLegacyLauncher(
        type: type, appName: "Custom", bundleID: "example.Custom", command: "custom")
      #expect(launcher.allowsExistingWindow == (type != .applescript))
      let encoded = try JSONEncoder().encode(launcher)
      let decoded = try JSONDecoder().decode(AppLauncher.self, from: encoded)
      #expect(decoded == launcher)
    }
  }

  @Test("Safari templates explicitly compose Launch Services and AppleScript")
  func windowSpecificTemplatesAreComposed() {
    let safari = LauncherTemplate.safari.launcher
    let safariProfile = LauncherTemplate.safariProfile.launcher

    #expect(safari.steps.map(\.type) == [.launchServices, .applescript])
    #expect(safariProfile.steps.map(\.type) == [.launchServices, .applescript])

    guard case .launchServices(let launch) = safari.steps[0].action,
      case .appleScript(let script) = safari.steps[1].action
    else {
      Issue.record("Expected Safari to launch first and configure its window second")
      return
    }
    #expect(launch.target.isEmpty)
    #expect(!launch.activates)
    #expect(script.contains("New Window"))
  }

  @Test("The iTerm template opens the project in a new iTerm process")
  func iTermTemplateIsASeparateInstance() throws {
    let iterm = LauncherTemplate.iterm.launcher
    #expect(iterm.steps.map(\.type) == [.launchServices])
    #expect(!iterm.allowsExistingWindow)
    let configuration = try #require(launchServicesConfiguration(of: iterm.steps[0]))
    #expect(configuration.target == "$PATH")
    #expect(configuration.createsNewApplicationInstance)
    #expect(configuration.activates)
  }

  @Test("A composed launcher round-trips typed per-step configuration")
  func composedLauncherRoundTrip() throws {
    let original = AppLauncher(
      label: "Configured App",
      appName: "Configured App",
      bundleID: "com.example.configured",
      steps: [
        WorkspaceLauncherStep(
          action: .launchServices(
            WorkspaceLaunchServicesConfiguration(
              target: "$PATH",
              arguments: ["--workspace", "$NAME"],
              environment: [
                WorkspaceEnvironmentVariable(name: "PROJECT_ROOT", value: "$PATH")
              ],
              createsNewApplicationInstance: true,
              activates: false))),
        WorkspaceLauncherStep(
          action: .appleScript("tell application \"Configured App\" to activate")),
      ])

    let decoded = try JSONDecoder().decode(
      AppLauncher.self, from: JSONEncoder().encode(original))

    #expect(decoded == original)
  }

  @Test("Launch Services configurations decoded without activation preserve the old default")
  func launchServicesActivationDecodeDefault() throws {
    let data = Data(
      """
      {
        "target": "$PATH",
        "arguments": [],
        "environment": [],
        "createsNewApplicationInstance": false
      }
      """.utf8)

    let configuration = try JSONDecoder().decode(
      WorkspaceLaunchServicesConfiguration.self, from: data)

    #expect(configuration.activates)
  }

  @Test("Legacy launchers infer known bundle IDs from their app names")
  func legacyLauncherBundleIDMigration() throws {
    let id = UUID()
    let data = Data(
      """
      {
        "id": "\(id.uuidString)",
        "label": "",
        "type": "applescript",
        "command": "launch iTerm",
        "appName": "iTerm"
      }
      """.utf8)

    let launcher = try JSONDecoder().decode(AppLauncher.self, from: data)

    #expect(launcher.bundleID == "com.googlecode.iterm2")
  }

  @Test("Standard launcher templates declare their launch mechanism and application bundle")
  func standardTemplateConfiguration() {
    #expect(LauncherTemplate.iterm.launcher.bundleID == "com.googlecode.iterm2")

    #expect(LauncherTemplate.intellij.launcher.bundleID == "com.jetbrains.intellij")
    #expect(LauncherTemplate.intellij.launcher.steps.map(\.type) == [.launchServices])
    guard
      case .launchServices(let intelliJConfiguration) =
        LauncherTemplate.intellij.launcher.steps[0].action
    else {
      Issue.record("Expected the IntelliJ Launch Services configuration")
      return
    }
    #expect(intelliJConfiguration.target == "$PATH")
    #expect(intelliJConfiguration.activates)

    #expect(LauncherTemplate.tower.launcher.bundleID == "com.fournova.Tower3")

    #expect(LauncherTemplate.safari.launcher.bundleID == "com.apple.Safari")

    #expect(LauncherTemplate.safariProfile.launcher.bundleID == "com.apple.Safari")
    guard
      case .launchServices(let safariConfiguration) =
        LauncherTemplate.safari.launcher.steps[0].action,
      case .launchServices(let safariProfileConfiguration) =
        LauncherTemplate.safariProfile.launcher.steps[0].action
    else {
      Issue.record("Expected the Safari Launch Services configurations")
      return
    }
    #expect(!safariConfiguration.activates)
    #expect(!safariProfileConfiguration.activates)
    #expect(LauncherTemplate.genericOpen.launcher.bundleID.isEmpty)
    #expect(LauncherTemplate.genericShell.launcher.bundleID.isEmpty)
    #expect(LauncherTemplate.genericAppleScript.launcher.steps.map(\.type) == [.applescript])
    #expect(LauncherTemplate.genericAppleScript.launcher.bundleID.isEmpty)
    #expect(
      LauncherTemplate.genericLaunchServices.launcher.steps.map(\.type) == [.launchServices])
    #expect(LauncherTemplate.genericLaunchServices.launcher.bundleID.isEmpty)
    guard
      case .launchServices(let genericConfiguration) =
        LauncherTemplate.genericLaunchServices.launcher.steps[0].action
    else {
      Issue.record("Expected the generic Launch Services configuration")
      return
    }
    #expect(genericConfiguration.activates)
  }

  @Test("Legacy stock iTerm launchers migrate to the single new-instance launch")
  func legacyITermLauncherLaunchServicesMigration() throws {
    let migrated = try decodeLegacyLauncher(
      type: .applescript,
      appName: "iTerm",
      bundleID: "com.googlecode.iterm2",
      command: """
        tell application "iTerm"
          set newWindow to (create window with default profile)
          tell current session of newWindow
            write text "cd $PATH"
          end tell
        end tell
        """)

    #expect(migrated.steps.map(\.action) == LauncherTemplate.iterm.launcher.steps.map(\.action))
    #expect(!migrated.allowsExistingWindow)
  }

  @Test("Shell-prefixed stock iTerm launchers migrate to the single new-instance launch")
  func currentITermLauncherLaunchServicesMigration() throws {
    let migrated = try decodeLegacyLauncher(
      type: .applescript,
      appName: "iTerm",
      bundleID: "com.googlecode.iterm2",
      command: """
        do shell script "/usr/bin/open -g -b com.googlecode.iterm2"
        tell application "iTerm"
          set newWindow to (create window with default profile)
          tell current session of newWindow
            write text "cd $PATH"
          end tell
        end tell
        """)

    #expect(migrated.steps.map(\.action) == LauncherTemplate.iterm.launcher.steps.map(\.action))
  }

  @Test("Stock composed iTerm launchers saved by earlier releases migrate to one step")
  func composedStockITermLauncherMigration() throws {
    let stock = AppLauncher(
      appName: "iTerm", bundleID: "com.googlecode.iterm2", allowsExistingWindow: false,
      steps: [
        WorkspaceLauncherStep(
          action: .launchServices(WorkspaceLaunchServicesConfiguration(activates: false))),
        WorkspaceLauncherStep(action: .appleScript(AppLauncher.iTermCommand)),
      ])
    let migrated = try JSONDecoder().decode(AppLauncher.self, from: JSONEncoder().encode(stock))
    #expect(migrated.id == stock.id)
    #expect(migrated.steps.map(\.action) == LauncherTemplate.iterm.launcher.steps.map(\.action))
    #expect(migrated.steps[0].id == stock.steps[0].id)
    #expect(!migrated.allowsExistingWindow)

    // The migrated form is stable.
    let again = try JSONDecoder().decode(AppLauncher.self, from: JSONEncoder().encode(migrated))
    #expect(again == migrated)
  }

  @Test(
    "A composed stock iTerm payload without a stored policy infers a new window; a stored policy wins",
    arguments: [nil, true, false])
  func composedStockITermPolicyInference(storedPolicy: Bool?) throws {
    let stock = AppLauncher(
      appName: "iTerm", bundleID: "com.googlecode.iterm2",
      steps: [
        WorkspaceLauncherStep(
          action: .launchServices(WorkspaceLaunchServicesConfiguration(activates: false))),
        WorkspaceLauncherStep(action: .appleScript(AppLauncher.iTermCommand)),
      ])
    var object = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(stock)) as? [String: Any])
    object["allowsExistingWindow"] = storedPolicy

    let decoded = try JSONDecoder().decode(
      AppLauncher.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.steps.map(\.action) == LauncherTemplate.iterm.launcher.steps.map(\.action))
    #expect(decoded.allowsExistingWindow == (storedPolicy ?? false))
    let again = try JSONDecoder().decode(AppLauncher.self, from: JSONEncoder().encode(decoded))
    #expect(again == decoded)
  }

  @Test("Composed iTerm launchers with custom steps are not migrated")
  func composedCustomITermLauncherIsNotMigrated() throws {
    let customScript = AppLauncher(
      appName: "iTerm", bundleID: "com.googlecode.iterm2", allowsExistingWindow: false,
      steps: [
        WorkspaceLauncherStep(
          action: .launchServices(WorkspaceLaunchServicesConfiguration(activates: false))),
        WorkspaceLauncherStep(action: .appleScript("tell application \"iTerm\" to activate")),
      ])
    let customLaunch = AppLauncher(
      appName: "iTerm", bundleID: "com.googlecode.iterm2", allowsExistingWindow: false,
      steps: [
        WorkspaceLauncherStep(
          action: .launchServices(
            WorkspaceLaunchServicesConfiguration(arguments: ["--flag"], activates: false))),
        WorkspaceLauncherStep(action: .appleScript(AppLauncher.iTermCommand)),
      ])
    for launcher in [customScript, customLaunch] {
      let decoded = try JSONDecoder().decode(AppLauncher.self, from: JSONEncoder().encode(launcher))
      #expect(decoded == launcher)
    }
  }

  @Test("Custom iTerm AppleScripts are not replaced by the stock migration")
  func customITermLauncherIsNotMigrated() throws {
    let decoded = try decodeLegacyLauncher(
      type: .applescript,
      appName: "iTerm",
      bundleID: "com.googlecode.iterm2",
      command: "tell application \"iTerm\" to create tab with default profile")

    #expect(decoded.steps.map(\.type) == [.applescript])
    #expect(
      decoded.steps.first?.action
        == .appleScript("tell application \"iTerm\" to create tab with default profile"))
  }

  @Test("Stock project launchers migrate from shell helpers to Launch Services")
  func stockProjectLauncherMigration() throws {
    let migratedIntelliJ = try decodeLegacyLauncher(
      type: .shell,
      appName: "IntelliJ IDEA",
      bundleID: "com.jetbrains.intellij",
      command: "idea \"$PATH\"")
    let migratedTower = try decodeLegacyLauncher(
      type: .shell,
      appName: "Tower",
      bundleID: "com.fournova.Tower3",
      command: "gittower \"$PATH\"")

    #expect(migratedIntelliJ.steps.map(\.type) == [.launchServices])
    guard case .launchServices(let configuration) = migratedIntelliJ.steps[0].action else {
      Issue.record("Expected migrated IntelliJ Launch Services configuration")
      return
    }
    #expect(configuration.target == "$PATH")
    #expect(configuration.activates)
    #expect(
      migratedTower.steps.map(\.action) == LauncherTemplate.tower.launcher.steps.map(\.action))
    #expect(!migratedTower.allowsExistingWindow)
  }

  @Test("The Tower template opens each workspace's repository in a new Tower window")
  func towerTemplateOpensNewWindow() {
    let tower = LauncherTemplate.tower.launcher

    // Tower otherwise shows the repository in its key window, replacing another
    // workspace's repository; its bundled CLI's --new-window flag prevents that.
    // The CLI is found through the app's bundle ID, and both paths arrive as
    // environment data rather than shell source.
    #expect(
      tower.steps.map(\.action) == [
        .shell(
          "\"$SPACEBALLS_APP_PATH/Contents/MacOS/gittower\" --new-window \"$SPACEBALLS_WORKSPACE_PATH\"",
          waitsForExit: true)
      ])
    // Relocating the focused pre-existing window would move another workspace's
    // Tower window if Tower focuses it before the new window appears.
    #expect(!tower.allowsExistingWindow)
  }

  @Test("The Tower template keeps the workspace path out of shell source")
  func towerTemplateKeepsPathOutOfShellSource() {
    let path = "/tmp/Client \"A\"/$(printf SUBSTITUTED)/it's"

    let request = launcherData(LauncherTemplate.tower.launcher)
      .resolvedLaunchRequest(path: path, name: "Client")

    #expect(request.workspacePath == path)
    for step in request.steps {
      guard case .shell(let command, _) = step else { continue }
      #expect(!command.contains(path))
    }
  }

  @Test("Tower's CLI receives the workspace path verbatim, whatever its characters")
  func towerCLIReceivesPathVerbatim() throws {
    // A stand-in CLI inside a stand-in bundle, found by bundle ID as the real one is.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Tower Beta.app")
    let executables = app.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
    let cli = executables.appendingPathComponent("gittower")
    try "#!/bin/sh\nprintf '%s\\0' \"$@\" > \"$(dirname \"$0\")/received\"\n"
      .write(to: cli, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
    let path = "/tmp/Client \"A\"/$(printf SUBSTITUTED)/`printf TICK`/it's $HOME \\ end"

    let executor = WorkspaceLauncherExecutor(
      runProcess: WorkspaceLauncherExecutor.live.runProcess,
      openWithLaunchServices: { _ in Issue.record("Tower launches through its CLI") },
      applicationURL: { $0 == "com.fournova.Tower3" ? app : nil })
    try executor.execute(
      launcherData(LauncherTemplate.tower.launcher)
        .resolvedLaunchRequest(path: path, name: "Client"))

    let received = try String(
      contentsOf: executables.appendingPathComponent("received"), encoding: .utf8)
    #expect(received.split(separator: "\0").map(String.init) == ["--new-window", path])
  }

  @Test("Launchers saved from the window-reusing Tower template open a new window")
  func savedReusingTowerLauncherMigrates() throws {
    let stepID = UUID()
    let saved = AppLauncher(
      appName: "Tower",
      bundleID: "com.fournova.Tower3",
      allowsExistingWindow: true,
      steps: [
        WorkspaceLauncherStep(
          id: stepID,
          action: .launchServices(
            WorkspaceLaunchServicesConfiguration(target: "$PATH", activates: true)))
      ])

    let migrated = try roundTrip(saved)

    #expect(migrated.steps.map(\.id) == [stepID])
    #expect(migrated.steps.map(\.action) == LauncherTemplate.tower.launcher.steps.map(\.action))
    #expect(!migrated.allowsExistingWindow)
    #expect(try roundTrip(migrated) == migrated)
  }

  @Test(
    "Customized Tower launchers keep their pipeline and window policy",
    arguments: [
      // A different target, activation, or extra step is the user's own composition.
      [
        WorkspaceLauncherAction.launchServices(
          WorkspaceLaunchServicesConfiguration(target: "$PATH/app", activates: true))
      ],
      [.launchServices(WorkspaceLaunchServicesConfiguration(target: "$PATH", activates: false))],
      [
        .launchServices(WorkspaceLaunchServicesConfiguration(target: "$PATH", activates: true)),
        .appleScript("return 1"),
      ],
      [
        .launchServices(
          WorkspaceLaunchServicesConfiguration(
            target: "$PATH", arguments: ["--verbose"], activates: true))
      ],
      [
        .launchServices(
          WorkspaceLaunchServicesConfiguration(
            target: "$PATH",
            environment: [WorkspaceEnvironmentVariable(name: "GIT_DIR", value: "$PATH/.git")],
            activates: true))
      ],
      [
        .launchServices(
          WorkspaceLaunchServicesConfiguration(
            target: "$PATH", createsNewApplicationInstance: true, activates: true))
      ],
      // Re-enabling relocation on the migrated launcher is a deliberate choice.
      LauncherTemplate.tower.launcher.steps.map(\.action),
    ])
  func customizedTowerLauncherIsNotMigrated(actions: [WorkspaceLauncherAction]) throws {
    let saved = AppLauncher(
      appName: "Tower",
      bundleID: "com.fournova.Tower3",
      allowsExistingWindow: true,
      steps: actions.map { WorkspaceLauncherStep(action: $0) })

    #expect(try roundTrip(saved) == saved)
  }

  @Test("Only Tower's stock Launch Services pipeline is replaced by the Tower migration")
  func otherAppsWithTowerPipelineAreNotMigrated() throws {
    let saved = AppLauncher(
      appName: "IntelliJ IDEA",
      bundleID: "com.jetbrains.intellij",
      allowsExistingWindow: true,
      steps: [
        WorkspaceLauncherStep(
          action: .launchServices(
            WorkspaceLaunchServicesConfiguration(target: "$PATH", activates: true)))
      ])

    #expect(try roundTrip(saved) == saved)
  }

  @Test("Custom project shell launchers are not migrated")
  func customProjectLauncherIsNotMigrated() throws {
    let decoded = try decodeLegacyLauncher(
      type: .shell,
      appName: "IntelliJ IDEA",
      bundleID: "com.jetbrains.intellij",
      command: "idea --line 42 \"$PATH\"")

    #expect(decoded.steps.map(\.type) == [.shell])
    #expect(decoded.steps.first?.action == .shell("idea --line 42 \"$PATH\"", waitsForExit: false))
  }

  @Test("Stock Safari scripts remove their embedded shell launch")
  func stockSafariLauncherMigration() throws {
    let migratedSafari = try decodeLegacyLauncher(
      type: .applescript,
      appName: "Safari",
      bundleID: "com.apple.Safari",
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
        """)
    let migratedSafariProfile = try decodeLegacyLauncher(
      label: "$NAME",
      type: .applescript,
      appName: "Safari",
      bundleID: "com.apple.Safari",
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
        """)
    let migratedCurrentSafari = try decodeLegacyLauncher(
      type: .applescript,
      appName: "Safari",
      bundleID: "com.apple.Safari",
      command: AppLauncher.safariCommand)

    #expect(migratedSafari.steps.map(\.type) == [.launchServices, .applescript])
    #expect(migratedSafariProfile.steps.map(\.type) == [.launchServices, .applescript])
    #expect(migratedCurrentSafari.steps.map(\.type) == [.launchServices, .applescript])
    guard case .launchServices(let safariConfiguration) = migratedSafari.steps[0].action,
      case .launchServices(let profileConfiguration) = migratedSafariProfile.steps[0].action,
      case .launchServices(let currentSafariConfiguration) =
        migratedCurrentSafari.steps[0].action,
      case .appleScript(let safariScript) = migratedSafari.steps[1].action,
      case .appleScript(let profileScript) = migratedSafariProfile.steps[1].action
    else {
      Issue.record("Expected migrated Safari AppleScript steps")
      return
    }
    #expect(!safariConfiguration.activates)
    #expect(!profileConfiguration.activates)
    #expect(!currentSafariConfiguration.activates)
    #expect(!safariScript.contains("do shell script"))
    #expect(safariScript.contains("New Window"))
    #expect(!profileScript.contains("do shell script"))
    #expect(profileScript.contains("New $PROFILE Window"))
  }

  @Test("Explicit bundle IDs survive encoding and decoding")
  func bundleIDRoundTrip() throws {
    let original = AppLauncher(
      label: "Terminal", type: .open, appName: "Terminal",
      bundleID: "com.apple.Terminal", command: "Terminal")

    let decoded = try JSONDecoder().decode(
      AppLauncher.self, from: JSONEncoder().encode(original))

    #expect(decoded == original)
  }

  private func launchServicesConfiguration(
    of step: WorkspaceLauncherStep
  ) -> WorkspaceLaunchServicesConfiguration? {
    guard case .launchServices(let configuration) = step.action else { return nil }
    return configuration
  }

  /// The restore-time form of a launcher, as the app hands it to the restorer.
  private func launcherData(_ launcher: AppLauncher) -> LauncherData {
    LauncherData(
      label: launcher.label,
      steps: launcher.steps,
      appName: launcher.appName,
      bundleID: launcher.bundleID,
      allowsExistingWindow: launcher.allowsExistingWindow)
  }

  private func roundTrip(_ launcher: AppLauncher) throws -> AppLauncher {
    try JSONDecoder().decode(AppLauncher.self, from: JSONEncoder().encode(launcher))
  }

  private func decodeLegacyLauncher(
    label: String = "",
    type: LaunchType,
    appName: String,
    bundleID: String,
    command: String
  ) throws -> AppLauncher {
    let object: [String: Any] = [
      "id": UUID().uuidString,
      "label": label,
      "type": type.rawValue,
      "command": command,
      "appName": appName,
      "bundleID": bundleID,
    ]
    return try JSONDecoder().decode(
      AppLauncher.self, from: JSONSerialization.data(withJSONObject: object))
  }
}
