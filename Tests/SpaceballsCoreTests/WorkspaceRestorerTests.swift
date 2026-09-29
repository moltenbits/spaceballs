import Foundation
import Testing

@testable import SpaceballsCore

@Suite("Workspace Restoration Layout Integration")
struct WorkspaceRestorerTests {
  @Test(
    "Focus changes during settling are repaired before launching, or fail closed",
    arguments: [true, false])
  func focusChangesDuringSettling(recovers: Bool) throws {
    let target = space(id: 101, uuid: "focus-race")
    let other = space(id: 202, uuid: "other")
    var current = target
    var clicks = 0
    var launches = 0
    let hooks = WorkspaceRestorerHooks(
      createDefaultSpaces: { _, _ in 0 },
      allSpaces: {
        [
          SpaceInfo(
            id: target.id, uuid: target.uuid, type: .desktop,
            displayUUID: target.displayUUID, isCurrent: current.id == target.id),
          SpaceInfo(
            id: other.id, uuid: other.uuid, type: .desktop,
            displayUUID: other.displayUUID, isCurrent: current.id == other.id),
        ]
      },
      windowsBySpace: { [:] }, switchToSpace: { _ in current = target },
      focusDisplay: { _ in
        clicks += 1
        if clicks == 1 || !recovers { current = other }
      },
      executeLauncher: { _ in
        #expect(current.id == target.id)
        launches += 1
      },
      relocateFocusedWindow: { _, _, _, _ in .onTarget }, sleep: { _ in })
    let restorer = WorkspaceRestorer(
      spaceNameStore: makeNameStore([target.uuid: "Work"]),
      windowLayoutRestorer: nil, hooks: hooks)
    let result = try restorer.restoreSync(
      workspaces: [
        WorkspaceConfigData(
          id: "work", name: "Work", path: nil,
          launchers: [LauncherData(label: "", type: .open, command: "Safari")])
      ],
      defaultNames: ["Work"])
    #expect(launches == (recovers ? 1 : 0))
    #expect(result.errors.isEmpty == recovers)
    #expect(clicks <= 3)
  }

  @Test(
    "Launcher diagnostics identify focus changes without logging launch payloads",
    arguments: [true, false])
  func launcherFocusDiagnostics(fails: Bool) throws {
    let target = space(id: 101, uuid: "diagnostics")
    var current = target
    var frontmost = "com.example.before"
    var logs: [String] = []
    let hooks = WorkspaceRestorerHooks(
      createDefaultSpaces: { _, _ in 0 }, allSpaces: { [current] },
      windowsBySpace: { [:] },
      switchToSpace: { _ in current = target },
      focusDisplay: { _ in frontmost = "com.apple.finder" },
      executeLauncher: { _ in
        current = space(id: 202, uuid: "other")
        frontmost = "com.example.launched"
        if fails { throw WorkspaceLauncherError.missingLaunchServicesBundleID }
      },
      relocateFocusedWindow: { _, _, _, _ in .onTarget }, sleep: { _ in },
      diagnosticsEnabled: { true }, frontmostApplication: { frontmost },
      logDiagnostic: { logs.append($0) })
    let restorer = WorkspaceRestorer(
      spaceNameStore: makeNameStore([target.uuid: "Work"]), windowLayoutRestorer: nil, hooks: hooks)
    _ = try restorer.restoreSync(
      workspaces: [
        WorkspaceConfigData(
          id: "workspace-id", name: "Work", path: "/private/path",
          launchers: [
            LauncherData(
              label: "private-label",
              steps: [
                WorkspaceLauncherStep(
                  action: .launchServices(.init(target: "$PATH", activates: true)))
              ],
              bundleID: "com.example.launched")
          ])
      ], defaultNames: ["Work"])
    let before = try #require(logs.first { $0.contains("phase=before-launch") })
    #expect(before.contains("workspace=workspace-id launcher=1 app=com.example.launched"))
    #expect(before.contains("launchServices(activates=true)"))
    #expect(before.contains("currentSpaces=[101@display-A]"))
    #expect(before.contains("frontmost=com.apple.finder"))
    let after = try #require(
      logs.first {
        $0.contains(fails ? "phase=launcher-failed" : "phase=after-execute")
      })
    #expect(after.contains("currentSpaces=[202@display-A]"))
    #expect(after.contains("frontmost=com.example.launched"))
    #expect(
      logs.contains {
        $0.contains("phase=before-refocus") && $0.contains("launcher=1")
          && $0.contains("currentSpaces=[202@display-A]")
      })
    #expect(logs.last?.contains("currentSpaces=[101@display-A]") == true)
    #expect(!logs.joined().contains("/private/path"))
    #expect(!logs.joined().contains("private-label"))
  }

  @Test("Disabled launcher diagnostics do not read frontmost app state or emit entries")
  func launcherDiagnosticsDisabled() throws {
    let target = space(id: 101, uuid: "diagnostics-off")
    let hooks = WorkspaceRestorerHooks(
      createDefaultSpaces: { _, _ in 0 }, allSpaces: { [target] }, windowsBySpace: { [:] },
      switchToSpace: { _ in }, focusDisplay: { _ in }, executeLauncher: { _ in },
      relocateFocusedWindow: { _, _, _, _ in .onTarget }, sleep: { _ in },
      diagnosticsEnabled: { false },
      frontmostApplication: {
        Issue.record("Unexpected focus read")
        return ""
      },
      logDiagnostic: { _ in Issue.record("Unexpected diagnostic") })
    let restorer = WorkspaceRestorer(
      spaceNameStore: makeNameStore([target.uuid: "Work"]), windowLayoutRestorer: nil, hooks: hooks)
    _ = try restorer.restoreSync(
      workspaces: [
        WorkspaceConfigData(
          id: "work", name: "Work", path: nil,
          launchers: [LauncherData(label: "", type: .open, command: "Safari")])
      ],
      defaultNames: ["Work"])
  }

  @Test(
    "Reactivating a named workspace reuses its Space and opens only missing apps",
    arguments: ["Work", "work", "101", "Desktop 1"])
  func reactivatePartialWorkspace(name: String) throws {
    let other = space(id: 101, uuid: "other")
    let target = space(id: 102, uuid: "workspace", displayUUID: "display-B")
    let names = makeNameStore([target.uuid: name == "work" ? "Work" : name])
    var creationRequests: [[String]] = []
    var switched: [UInt64] = []
    var launched: [String] = []
    let terminal = WindowInfo(
      id: 1, ownerName: "iTerm2", name: "Work", pid: 10, bounds: .zero,
      spaceIDs: [target.id])
    let safariElsewhere = WindowInfo(
      id: 2, ownerName: "Safari", name: "Other", pid: 20, bounds: .zero,
      spaceIDs: [other.id])
    let hooks = WorkspaceRestorerHooks(
      createDefaultSpaces: { requested, _ in
        creationRequests.append(requested)
        return 0
      },
      allSpaces: { [other, target] },
      windowsBySpace: { [target.id: [terminal], other.id: [safariElsewhere]] },
      switchToSpace: { switched.append($0) },
      focusDisplay: { #expect($0 == target.id) },
      executeLauncher: { launched.append($0.bundleID) },
      relocateFocusedWindow: { _, spaceID, _, _ in
        #expect(spaceID == target.id)
        return .onTarget
      },
      bundleIDForPID: { $0 == 10 ? "com.googlecode.iterm2" : "com.apple.Safari" },
      sleep: { _ in })
    let restorer = WorkspaceRestorer(
      spaceNameStore: names, windowLayoutRestorer: nil, hooks: hooks)
    let result = try restorer.restoreSync(
      workspaces: [
        WorkspaceConfigData(
          id: "work", name: name, path: nil,
          launchers: [
            LauncherData(
              label: "Terminal", type: .open, command: "iTerm",
              appName: "iTerm", bundleID: "com.googlecode.iterm2"),
            LauncherData(
              label: "Browser", type: .open, command: "Safari",
              appName: "Safari", bundleID: "com.apple.Safari"),
          ])
      ], defaultNames: [name])

    #expect(creationRequests.isEmpty)
    #expect(switched == [target.id])
    #expect(launched == ["com.apple.Safari"])
    #expect(result.spacesCreated == 0)
    #expect(result.appsLaunched == 1)
    #expect(result.errors.isEmpty)
  }

  @Test("Reactivating a complete workspace still switches to its existing Space")
  func reactivateCompleteWorkspace() throws {
    let target = space(id: 101, uuid: "complete")
    var switched: [UInt64] = []
    let existing = WindowInfo(
      id: 1, ownerName: "Safari", name: "Work", pid: 10, bounds: .zero,
      spaceIDs: [target.id])
    let hooks = WorkspaceRestorerHooks(
      createDefaultSpaces: { _, _ in
        Issue.record("Must not create a Space")
        return 0
      },
      allSpaces: { [target] },
      windowsBySpace: { [target.id: [existing]] },
      switchToSpace: { switched.append($0) },
      focusDisplay: { _ in },
      executeLauncher: { _ in Issue.record("Must not relaunch an existing app") },
      relocateFocusedWindow: { _, _, _, _ in .onTarget },
      sleep: { _ in })
    let restorer = WorkspaceRestorer(
      spaceNameStore: makeNameStore([target.uuid: "Work"]), windowLayoutRestorer: nil, hooks: hooks)
    let result = try restorer.restoreSync(
      workspaces: [
        WorkspaceConfigData(
          id: "work", name: "Work", path: nil,
          launchers: [LauncherData(label: "", type: .open, command: "Safari", appName: "Safari")])
      ],
      defaultNames: ["Work"])
    #expect(switched == [target.id])
    #expect(result.appsLaunched == 0)
    #expect(result.errors.isEmpty)
  }

  @Test("Bundle identity takes precedence over app labels", arguments: [true, false])
  func existingAppIdentity(matchesBundle: Bool) throws {
    let target = space(id: 101, uuid: "identity")
    var launches = 0
    let existing = WindowInfo(
      id: 1, ownerName: "Safari", name: "Work", pid: 10, bounds: .zero,
      spaceIDs: [target.id])
    let hooks = WorkspaceRestorerHooks(
      createDefaultSpaces: { _, _ in 0 },
      allSpaces: { [target] }, windowsBySpace: { [target.id: [existing]] },
      switchToSpace: { _ in }, focusDisplay: { _ in },
      executeLauncher: { _ in launches += 1 },
      relocateFocusedWindow: { _, _, _, _ in .onTarget },
      bundleIDForPID: { _ in matchesBundle ? "com.apple.Safari" : "com.example.other" },
      sleep: { _ in })
    let restorer = WorkspaceRestorer(
      spaceNameStore: makeNameStore([target.uuid: "Work"]), windowLayoutRestorer: nil, hooks: hooks)
    _ = try restorer.restoreSync(
      workspaces: [
        WorkspaceConfigData(
          id: "work", name: "Work", path: nil,
          launchers: [
            LauncherData(
              label: "", type: .open, command: "Safari",
              appName: matchesBundle ? "" : "Safari", bundleID: "com.apple.Safari")
          ])
      ],
      defaultNames: ["Work"])
    #expect(launches == (matchesBundle ? 0 : 1))
  }

  @Test("Only absent workspace Spaces are created; stale names cannot prevent recreation")
  func createOnlyMissingSpaces() throws {
    let existing = space(id: 101, uuid: "existing")
    let newSpace = space(id: 102, uuid: "new")
    let names = makeNameStore([existing.uuid: "Work", "stale": "Personal"])
    var spaces = [existing]
    var switched: [UInt64] = []
    let hooks = WorkspaceRestorerHooks(
      createDefaultSpaces: { requested, store in
        #expect(requested == ["Personal"])
        spaces.append(newSpace)
        store.setCustomName("Personal", forSpaceUUID: newSpace.uuid)
        return 1
      },
      allSpaces: { spaces }, windowsBySpace: { [:] },
      switchToSpace: { switched.append($0) }, focusDisplay: { _ in },
      executeLauncher: { _ in Issue.record("No launchers configured") },
      relocateFocusedWindow: { _, _, _, _ in .onTarget }, sleep: { _ in })
    let restorer = WorkspaceRestorer(
      spaceNameStore: names, windowLayoutRestorer: nil, hooks: hooks)
    let result = try restorer.restoreSync(
      workspaces: [
        WorkspaceConfigData(id: "work", name: "Work", path: nil, launchers: []),
        WorkspaceConfigData(id: "personal", name: "Personal", path: nil, launchers: []),
      ], defaultNames: ["Work", "Personal"])
    #expect(switched == [existing.id, newSpace.id])
    #expect(result.spacesCreated == 1)
    #expect(result.appsLaunched == 0)
    #expect(result.errors.isEmpty)
  }

  @Test("An unresolved workspace reports an error without launching on another Space")
  func missingSpaceDoesNotLaunch() throws {
    let other = space(id: 101, uuid: "other")
    let hooks = WorkspaceRestorerHooks(
      createDefaultSpaces: { _, _ in 0 }, allSpaces: { [other] }, windowsBySpace: { [:] },
      switchToSpace: { _ in Issue.record("Must not switch to an unrelated Space") },
      focusDisplay: { _ in }, executeLauncher: { _ in Issue.record("Must not launch") },
      relocateFocusedWindow: { _, _, _, _ in .onTarget }, sleep: { _ in })
    let restorer = WorkspaceRestorer(
      spaceNameStore: makeNameStore([:]), windowLayoutRestorer: nil, hooks: hooks)
    let result = try restorer.restoreSync(
      workspaces: [
        WorkspaceConfigData(
          id: "work", name: "Desktop 1", path: nil,
          launchers: [LauncherData(label: "", type: .open, command: "Safari")])
      ],
      defaultNames: ["Desktop 1"])
    #expect(result.errors.count == 1)
    #expect(result.appsLaunched == 0)
  }

  @Test("A display focus failure is recorded and written to the diagnostics log")
  func focusFailureIsLogged() throws {
    let target = space(id: 101, uuid: "target")
    var logs: [String] = []
    let hooks = WorkspaceRestorerHooks(
      createDefaultSpaces: { _, _ in 0 }, allSpaces: { [target] }, windowsBySpace: { [:] },
      switchToSpace: { _ in },
      focusDisplay: { _ in throw WorkspaceRestorerError.targetSpaceFocusFailed(spaceID: 101) },
      executeLauncher: { _ in Issue.record("Must not launch") },
      relocateFocusedWindow: { _, _, _, _ in .onTarget }, sleep: { _ in },
      diagnosticsEnabled: { true }, frontmostApplication: { "" },
      logDiagnostic: { logs.append($0) })
    let restorer = WorkspaceRestorer(
      spaceNameStore: makeNameStore([target.uuid: "Work"]), windowLayoutRestorer: nil, hooks: hooks)
    let result = try restorer.restoreSync(
      workspaces: [
        WorkspaceConfigData(
          id: "work", name: "Work", path: nil,
          launchers: [LauncherData(label: "", type: .open, command: "Safari")])
      ],
      defaultNames: ["Work"])
    #expect(result.errors.count == 1)
    #expect(result.appsLaunched == 0)
    let failure = try #require(logs.first { $0.contains("error") })
    #expect(failure.contains("Work"))
    #expect(failure.contains("Failed to switch"))
  }

  @Test(
    "A launcher failure is logged by type and status, never with its process output",
    arguments: [true, false])
  func launcherFailureLogIsPayloadFree(diagnostics: Bool) throws {
    let target = space(id: 101, uuid: "target")
    var logs: [String] = []
    let hooks = WorkspaceRestorerHooks(
      createDefaultSpaces: { _, _ in 0 }, allSpaces: { [target] }, windowsBySpace: { [:] },
      switchToSpace: { _ in }, focusDisplay: { _ in },
      executeLauncher: { _ in
        throw WorkspaceLauncherError.processFailed(
          type: "shell", status: 3, output: "SECRET-TOKEN in /private/leak")
      },
      relocateFocusedWindow: { _, _, _, _ in .onTarget }, sleep: { _ in },
      diagnosticsEnabled: { diagnostics }, frontmostApplication: { "" },
      logDiagnostic: { logs.append($0) })
    let restorer = WorkspaceRestorer(
      spaceNameStore: makeNameStore([target.uuid: "Work"]), windowLayoutRestorer: nil, hooks: hooks)
    let result = try restorer.restoreSync(
      workspaces: [
        WorkspaceConfigData(
          id: "work", name: "Work", path: nil,
          launchers: [
            LauncherData(label: "", type: .shell, command: "leak", appName: "Terminal")
          ])
      ],
      defaultNames: ["Work"])
    #expect(result.errors.count == 1)
    #expect(result.errors.first?.2.contains("SECRET-TOKEN") == true)
    guard diagnostics else {
      #expect(logs.isEmpty)
      return
    }
    let failure = try #require(logs.first { $0.hasPrefix("error ") })
    #expect(failure.contains("workspace=\"Work\""))
    #expect(failure.contains("app=\"Terminal\""))
    #expect(failure.contains("shell launcher exited with status 3"))
    #expect(!logs.joined().contains("SECRET-TOKEN"))
    #expect(!logs.joined().contains("/private/leak"))
  }

  @Test("Unknown errors are logged as domain and code, never their user info")
  func unknownErrorDiagnostic() {
    let error = NSError(
      domain: "com.example.launch", code: 7,
      userInfo: [
        NSLocalizedDescriptionKey: "SECRET-TOKEN in /private/leak",
        NSFilePathErrorKey: "/private/leak",
      ])
    #expect(WorkspaceRestorer.diagnosticDescription(of: error) == "com.example.launch code=7")
    #expect(
      WorkspaceRestorer.diagnosticDescription(
        of: WorkspaceRestorerError.targetSpaceFocusFailed(spaceID: 42))
        == "Could not safely focus workspace Space 42")
  }

  @Test(
    "Window reuse follows launcher policy even with an AppleScript step", arguments: [true, false])
  func composedWindowReusePolicy(allowsExisting: Bool) throws {
    let target = space(id: 101, uuid: "reuse-policy")
    var observed: Bool?
    let hooks = WorkspaceRestorerHooks(
      createDefaultSpaces: { _, _ in 0 },
      allSpaces: { [target] },
      windowsBySpace: { [:] },
      switchToSpace: { _ in },
      focusDisplay: { _ in },
      executeLauncher: { _ in },
      relocateFocusedWindow: { _, _, _, allowsExistingWindow in
        observed = allowsExistingWindow
        return .onTarget
      },
      sleep: { _ in })
    let restorer = WorkspaceRestorer(
      spaceNameStore: makeNameStore([target.uuid: "Work"]), windowLayoutRestorer: nil, hooks: hooks)
    _ = try restorer.restoreSync(
      workspaces: [
        WorkspaceConfigData(
          id: "work", name: "Work", path: nil,
          launchers: [
            LauncherData(
              label: "Tower",
              steps: [
                WorkspaceLauncherStep(action: .launchServices(.init(target: "$PATH"))),
                WorkspaceLauncherStep(action: .appleScript("return 1")),
              ],
              bundleID: "com.fournova.Tower3", allowsExistingWindow: allowsExisting)
          ])
      ],
      defaultNames: ["Work"])
    #expect(observed == allowsExisting)
  }

  @Test("Resolving shell variables preserves the wait policy", arguments: [true, false])
  func shellWaitPolicySurvivesResolution(waits: Bool) {
    let launcher = LauncherData(
      label: "",
      steps: [
        WorkspaceLauncherStep(action: .shell("echo $NAME", waitsForExit: waits))
      ])
    #expect(
      launcher.resolvedLaunchRequest(path: nil, name: "Work").steps == [
        .shell("echo Work", waitsForExit: waits)
      ])
  }

  private func makeNameStore(_ names: [String: String]) -> SpaceNameStore {
    let suite = "WorkspaceRestorerTests-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let store = SpaceNameStore(defaults: defaults)
    for (uuid, name) in names {
      store.setCustomName(name, forSpaceUUID: uuid)
    }
    return store
  }

  private func space(
    id: UInt64, uuid: String, displayUUID: String = "display-A"
  ) -> SpaceInfo {
    SpaceInfo(
      id: id, uuid: uuid, type: .desktop, displayUUID: displayUUID, isCurrent: true)
  }

  @Test("Workspace layout restore runs after missing apps are launched")
  func layoutRestoreRunsAfterLaunch() throws {
    let target = space(id: 101, uuid: "space-1")
    let names = makeNameStore([target.uuid: "Work"])
    var launched = false
    var restoredAfterLaunch = false

    let layoutRestorer = WorkspaceWindowLayoutRestorer(
      maximumAttempts: 1,
      retryInterval: 0,
      prepare: { workspaceID, spaceUUID, displayUUID, bundleIDs in
        #expect(workspaceID == "workspace-1")
        #expect(spaceUUID == target.uuid)
        #expect(displayUUID == target.displayUUID)
        #expect(bundleIDs == ["com.googlecode.iterm2"])
        return true
      },
      attempt: { _, _, _, _ in
        restoredAfterLaunch = launched
        return WindowLayoutRestoreAttempt(
          hasLayout: true, movedWindows: 1,
          restoredBundleIDs: ["com.googlecode.iterm2"], pendingBundleIDs: [])
      },
      sleep: { _ in })

    let hooks = WorkspaceRestorerHooks(
      createDefaultSpaces: { _, _ in 0 },
      allSpaces: { [target] },
      windowsBySpace: { [:] },
      switchToSpace: { _ in },
      focusDisplay: { _ in },
      executeLauncher: { _ in launched = true },
      relocateFocusedWindow: { _, _, _, _ in .onTarget },
      sleep: { _ in })
    let restorer = WorkspaceRestorer(
      spaceNameStore: names,
      windowLayoutRestorer: layoutRestorer,
      hooks: hooks)

    _ = try restorer.restoreSync(
      workspaces: [
        WorkspaceConfigData(
          id: "workspace-1", name: "Work", path: nil,
          launchers: [
            LauncherData(
              label: "Terminal", type: .open, command: "iTerm", appName: "iTerm",
              bundleID: "com.googlecode.iterm2")
          ])
      ],
      defaultNames: ["Work"])

    #expect(launched)
    #expect(restoredAfterLaunch)
  }

  @Test("Existing workspace windows are restored without relaunching")
  func existingWindowsAreRestored() throws {
    let target = space(id: 101, uuid: "space-1")
    let names = makeNameStore([target.uuid: "Work"])
    var switched = false
    var launched = false
    var attempts = 0

    let layoutRestorer = WorkspaceWindowLayoutRestorer(
      maximumAttempts: 1,
      retryInterval: 0,
      prepare: { _, _, _, bundleIDs in
        #expect(bundleIDs == ["com.googlecode.iterm2"])
        return true
      },
      attempt: { _, _, _, _ in
        attempts += 1
        return WindowLayoutRestoreAttempt(
          hasLayout: true, movedWindows: 1,
          restoredBundleIDs: ["com.googlecode.iterm2"], pendingBundleIDs: [])
      },
      sleep: { _ in })
    let existing = WindowInfo(
      id: 1, ownerName: "iTerm", name: "Work", pid: 100,
      bounds: .zero, spaceIDs: [target.id])
    let hooks = WorkspaceRestorerHooks(
      createDefaultSpaces: { _, _ in 0 },
      allSpaces: { [target] },
      windowsBySpace: { [target.id: [existing]] },
      switchToSpace: { _ in switched = true },
      focusDisplay: { _ in },
      executeLauncher: { _ in launched = true },
      relocateFocusedWindow: { _, _, _, _ in .onTarget },
      sleep: { _ in })
    let restorer = WorkspaceRestorer(
      spaceNameStore: names,
      windowLayoutRestorer: layoutRestorer,
      hooks: hooks)

    _ = try restorer.restoreSync(
      workspaces: [
        WorkspaceConfigData(
          id: "workspace-1", name: "Work", path: nil,
          launchers: [
            LauncherData(
              label: "Terminal", type: .open, command: "iTerm", appName: "iTerm",
              bundleID: "com.googlecode.iterm2")
          ])
      ],
      defaultNames: ["Work"])

    #expect(switched)
    #expect(!launched)
    #expect(attempts == 1)
  }

  @Test("A timed-out layout does not prevent the next workspace")
  func timeoutDoesNotPreventNextWorkspace() throws {
    let first = space(id: 101, uuid: "space-1")
    let second = space(id: 202, uuid: "space-2")
    let names = makeNameStore([first.uuid: "First", second.uuid: "Second"])
    var attemptedWorkspaces: [String] = []

    let layoutRestorer = WorkspaceWindowLayoutRestorer(
      maximumAttempts: 2,
      retryInterval: 0,
      prepare: { _, _, _, _ in true },
      attempt: { workspaceID, _, _, _ in
        attemptedWorkspaces.append(workspaceID)
        return WindowLayoutRestoreAttempt(
          hasLayout: true, movedWindows: 0,
          restoredBundleIDs: [], pendingBundleIDs: ["com.missing.app"])
      },
      sleep: { _ in })
    let hooks = WorkspaceRestorerHooks(
      createDefaultSpaces: { _, _ in 0 },
      allSpaces: { [first, second] },
      windowsBySpace: { [:] },
      switchToSpace: { _ in },
      focusDisplay: { _ in },
      executeLauncher: { _ in },
      relocateFocusedWindow: { _, _, _, _ in .onTarget },
      sleep: { _ in })
    let restorer = WorkspaceRestorer(
      spaceNameStore: names,
      windowLayoutRestorer: layoutRestorer,
      hooks: hooks)

    _ = try restorer.restoreSync(
      workspaces: [
        WorkspaceConfigData(
          id: "workspace-1", name: "First", path: nil,
          launchers: [LauncherData(label: "One", type: .open, command: "One")]),
        WorkspaceConfigData(
          id: "workspace-2", name: "Second", path: nil,
          launchers: [LauncherData(label: "Two", type: .open, command: "Two")]),
      ],
      defaultNames: ["First", "Second"])

    #expect(attemptedWorkspaces.filter { $0 == "workspace-1" }.count == 2)
    #expect(attemptedWorkspaces.filter { $0 == "workspace-2" }.count == 2)
  }

  @Test("A launcher that steals Space focus is relocated before the next launcher")
  func launcherFocusStealIsCorrected() throws {
    let targetID: UInt64 = 101
    let otherID: UInt64 = 202
    let targetUUID = "space-work"
    let names = makeNameStore([targetUUID: "Work"])
    var currentSpaceID = otherID
    var switchTargets: [UInt64] = []
    var launches: [String] = []
    var relocations: [(bundleID: String, targetSpaceID: UInt64)] = []
    var towerPlacementAttempts = 0

    let spaces: () -> [SpaceInfo] = {
      [
        SpaceInfo(
          id: targetID, uuid: targetUUID, type: .desktop,
          displayUUID: "display-A", isCurrent: currentSpaceID == targetID),
        SpaceInfo(
          id: otherID, uuid: "space-other", type: .desktop,
          displayUUID: "display-A", isCurrent: currentSpaceID == otherID),
      ]
    }
    let hooks = WorkspaceRestorerHooks(
      createDefaultSpaces: { _, _ in 0 },
      allSpaces: spaces,
      windowsBySpace: { [:] },
      switchToSpace: { target in
        switchTargets.append(target)
        currentSpaceID = target
      },
      focusDisplay: { _ in },
      executeLauncher: { request in
        #expect(currentSpaceID == targetID)
        guard let step = request.steps.first else { return }
        switch step {
        case .openApplication(let applicationName):
          launches.append(applicationName)
        case .appleScript(let source):
          launches.append(source)
        default:
          Issue.record("Unexpected launcher action")
        }
      },
      relocateFocusedWindow: { bundleID, target, _, allowsExistingWindow in
        relocations.append((bundleID, target))
        if bundleID == "com.apple.Safari" {
          #expect(!allowsExistingWindow)
          return .onTarget
        }
        #expect(allowsExistingWindow)
        towerPlacementAttempts += 1
        if towerPlacementAttempts == 1 {
          // The command returned before Tower finished activating its reused
          // window on another Space.
          currentSpaceID = otherID
          return .waiting
        }
        return .relocated
      },
      sleep: { _ in })
    let restorer = WorkspaceRestorer(
      spaceNameStore: names,
      windowLayoutRestorer: nil,
      hooks: hooks)

    _ = try restorer.restoreSync(
      workspaces: [
        WorkspaceConfigData(
          id: "workspace-1", name: "Work", path: nil,
          launchers: [
            LauncherData(
              label: "Tower", type: .open, command: "Tower", appName: "Tower",
              bundleID: "com.fournova.Tower3"),
            LauncherData(
              label: "Safari", type: .applescript, command: "Safari", appName: "Safari",
              bundleID: "com.apple.Safari"),
          ])
      ],
      defaultNames: ["Work"])

    #expect(launches == ["Tower", "Safari"])
    #expect(switchTargets == [targetID, targetID])
    #expect(
      relocations.map(\.bundleID) == [
        "com.fournova.Tower3", "com.fournova.Tower3", "com.apple.Safari",
      ])
    #expect(currentSpaceID == targetID)
  }

  @Test("Launch Services receives the resolved workspace target and bundle ID")
  func launchServicesRequestIsResolved() throws {
    let target = space(id: 101, uuid: "space-work")
    let names = makeNameStore([target.uuid: "My Work"])
    var capturedRequest: WorkspaceLaunchRequest?
    let hooks = WorkspaceRestorerHooks(
      createDefaultSpaces: { _, _ in 0 },
      allSpaces: { [target] },
      windowsBySpace: { [:] },
      switchToSpace: { _ in },
      focusDisplay: { _ in },
      executeLauncher: { capturedRequest = $0 },
      relocateFocusedWindow: { _, _, _, _ in .onTarget },
      sleep: { _ in })
    let restorer = WorkspaceRestorer(
      spaceNameStore: names,
      windowLayoutRestorer: nil,
      hooks: hooks)

    _ = try restorer.restoreSync(
      workspaces: [
        WorkspaceConfigData(
          id: "workspace-1", name: "My Work", path: "~/Projects/example",
          launchers: [
            LauncherData(
              label: "IDE", type: .launchServices, command: "$PATH",
              appName: "IntelliJ IDEA", bundleID: "com.jetbrains.intellij")
          ])
      ],
      defaultNames: ["My Work"])

    guard case .launchServices(let configuration) = capturedRequest?.steps.first else {
      Issue.record("Expected a Launch Services step")
      return
    }
    #expect(
      configuration.target == NSString(string: "~/Projects/example").expandingTildeInPath)
    #expect(capturedRequest?.bundleID == "com.jetbrains.intellij")
  }

  @Test("Workspace variables resolve throughout every composed step")
  func composedLauncherVariablesAreResolved() throws {
    let target = space(id: 101, uuid: "space-composed")
    let names = makeNameStore([target.uuid: "My Work"])
    var capturedRequest: WorkspaceLaunchRequest?
    let hooks = WorkspaceRestorerHooks(
      createDefaultSpaces: { _, _ in 0 },
      allSpaces: { [target] },
      windowsBySpace: { [:] },
      switchToSpace: { _ in },
      focusDisplay: { _ in },
      executeLauncher: { capturedRequest = $0 },
      relocateFocusedWindow: { _, _, _, _ in .onTarget },
      sleep: { _ in })
    let restorer = WorkspaceRestorer(
      spaceNameStore: names,
      windowLayoutRestorer: nil,
      hooks: hooks)

    _ = try restorer.restoreSync(
      workspaces: [
        WorkspaceConfigData(
          id: "workspace-1", name: "My Work", path: "~/Projects/example",
          launchers: [
            LauncherData(
              label: "Profile $NAME",
              steps: [
                WorkspaceLauncherStep(
                  action: .launchServices(
                    WorkspaceLaunchServicesConfiguration(
                      target: "$PATH",
                      arguments: ["--workspace", "${NAME}"],
                      environment: [
                        WorkspaceEnvironmentVariable(name: "ROOT", value: "${PATH}")
                      ],
                      createsNewApplicationInstance: true,
                      activates: false))),
                WorkspaceLauncherStep(
                  action: .appleScript("open profile $PROFILE for $NAME")),
              ],
              appName: "Configured App", bundleID: "com.example.Configured")
          ])
      ],
      defaultNames: ["My Work"])

    let expandedPath = NSString(string: "~/Projects/example").expandingTildeInPath
    guard let steps = capturedRequest?.steps, steps.count == 2 else {
      Issue.record("Expected both composed launcher steps")
      return
    }
    guard case .launchServices(let launch) = steps[0],
      case .appleScript(let script) = steps[1]
    else {
      Issue.record("Expected Launch Services followed by AppleScript")
      return
    }
    #expect(launch.target == expandedPath)
    #expect(launch.arguments == ["--workspace", "My Work"])
    #expect(launch.environment.first?.value == expandedPath)
    #expect(launch.createsNewApplicationInstance)
    #expect(!launch.activates)
    #expect(script == "open profile Profile My Work for My Work")
  }

  @Test("New-window launchers never relocate a pre-existing window")
  func relocationEligibilityProtectsExistingWindows() {
    let preexistingWindowIDs: Set<Int> = [700]

    #expect(
      !WorkspaceRestorer.canRelocateLaunchedWindow(
        windowID: 700,
        preexistingWindowIDs: preexistingWindowIDs,
        allowsExistingWindow: false))
    #expect(
      WorkspaceRestorer.canRelocateLaunchedWindow(
        windowID: 701,
        preexistingWindowIDs: preexistingWindowIDs,
        allowsExistingWindow: false))
    #expect(
      WorkspaceRestorer.canRelocateLaunchedWindow(
        windowID: 700,
        preexistingWindowIDs: preexistingWindowIDs,
        allowsExistingWindow: true))
  }

  @Test("Cold-launch windows are discovered by bundle ID without taking focus")
  func coldLaunchWindowsAreDiscoveredWithoutFocus() {
    let preexisting = WindowInfo(
      id: 700, ownerName: "iTerm2", name: "Existing", pid: 200,
      bounds: .zero, spaceIDs: [202])
    let coldLaunchWindow = WindowInfo(
      id: 701, ownerName: "iTerm2", name: "Work", pid: 200,
      bounds: .zero, spaceIDs: [202])
    let coldLaunchDefaultWindow = WindowInfo(
      id: 702, ownerName: "iTerm2", name: "Default", pid: 200,
      bounds: .zero, spaceIDs: [202])
    let focusedIntelliJWindow = WindowInfo(
      id: 800, ownerName: "IntelliJ IDEA", name: "Work", pid: 300,
      bounds: .zero, spaceIDs: [101])

    let windows = WorkspaceRestorer.newLauncherWindows(
      in: [
        101: [focusedIntelliJWindow],
        202: [preexisting, coldLaunchWindow, coldLaunchDefaultWindow],
      ],
      bundleID: "com.googlecode.iterm2",
      preexistingWindowIDs: [700],
      bundleIDForPID: { pid in
        switch pid {
        case 200: "com.googlecode.iterm2"
        case 300: "com.jetbrains.intellij"
        default: nil
        }
      })

    #expect(windows.map(\.id) == [701, 702])
  }

  @Test("Cold-launch iTerm windows are relocated while another app retains focus")
  func coldLaunchITermWindowsAreRelocatedWithoutFocus() throws {
    let target = space(id: 101, uuid: "space-work")
    let names = makeNameStore([target.uuid: "Work"])
    let preexisting = WindowInfo(
      id: 700, ownerName: "iTerm2", name: "Existing", pid: 200,
      bounds: .zero, spaceIDs: [202])
    let focusedIntelliJWindow = WindowInfo(
      id: 800, ownerName: "IntelliJ IDEA", name: "Work", pid: 300,
      bounds: .zero, spaceIDs: [target.id])
    let coldLaunchWindows = [
      WindowInfo(
        id: 701, ownerName: "iTerm2", name: "Work", pid: 200,
        bounds: .zero, spaceIDs: [202]),
      WindowInfo(
        id: 702, ownerName: "iTerm2", name: "Default", pid: 200,
        bounds: .zero, spaceIDs: [202]),
    ]
    var launched = false
    var focusedWindowAttempts = 0
    var relocatedWindowIDs: [Int] = []

    let hooks = WorkspaceRestorerHooks(
      createDefaultSpaces: { _, _ in 0 },
      allSpaces: { [target] },
      windowsBySpace: {
        var windows = [
          target.id: [focusedIntelliJWindow],
          202: [preexisting],
        ]
        if launched {
          windows[202]?.append(contentsOf: coldLaunchWindows)
        }
        return windows
      },
      switchToSpace: { _ in },
      focusDisplay: { _ in },
      executeLauncher: { _ in launched = true },
      relocateFocusedWindow: { _, _, _, _ in
        focusedWindowAttempts += 1
        return .waiting
      },
      bundleIDForPID: { pid in
        switch pid {
        case 200: "com.googlecode.iterm2"
        case 300: "com.jetbrains.intellij"
        default: nil
        }
      },
      relocateWindow: { windowID, targetSpaceID in
        #expect(targetSpaceID == target.id)
        relocatedWindowIDs.append(windowID)
        return true
      },
      sleep: { _ in })
    let restorer = WorkspaceRestorer(
      spaceNameStore: names,
      windowLayoutRestorer: nil,
      hooks: hooks)

    _ = try restorer.restoreSync(
      workspaces: [
        WorkspaceConfigData(
          id: "workspace-1", name: "Work", path: nil,
          launchers: [
            LauncherData(
              label: "Terminal", type: .applescript, command: "iTerm",
              appName: "iTerm", bundleID: "com.googlecode.iterm2")
          ])
      ],
      defaultNames: ["Work"])

    #expect(relocatedWindowIDs == [701, 702])
    #expect(focusedWindowAttempts == 0)
  }

  @Test("Launcher windows missing from the panel inventory are still relocated")
  func launcherWindowsMissingFromPanelAreRelocated() throws {
    let target = space(id: 101, uuid: "space-work")
    let names = makeNameStore([target.uuid: "Work"])
    let existingWindow = WorkspaceLauncherWindow(id: 700, spaceIDs: [202])
    let newWindow = WorkspaceLauncherWindow(id: 701, spaceIDs: [202])
    var launched = false
    var focusedWindowAttempts = 0
    var relocatedWindowIDs: [Int] = []

    let hooks = WorkspaceRestorerHooks(
      createDefaultSpaces: { _, _ in 0 },
      allSpaces: { [target] },
      // Reproduces the reboot failure: iTerm's windows never appear in the
      // normal inventory that feeds the Spaceballs app panel.
      windowsBySpace: { [:] },
      launcherWindows: { bundleID in
        #expect(bundleID == "com.googlecode.iterm2")
        return launched ? [existingWindow, newWindow] : [existingWindow]
      },
      switchToSpace: { _ in },
      focusDisplay: { _ in },
      executeLauncher: { _ in launched = true },
      relocateFocusedWindow: { _, _, _, _ in
        focusedWindowAttempts += 1
        return .waiting
      },
      relocateWindow: { windowID, targetSpaceID in
        #expect(targetSpaceID == target.id)
        relocatedWindowIDs.append(windowID)
        return true
      },
      sleep: { _ in })
    let restorer = WorkspaceRestorer(
      spaceNameStore: names,
      windowLayoutRestorer: nil,
      hooks: hooks)

    _ = try restorer.restoreSync(
      workspaces: [
        WorkspaceConfigData(
          id: "workspace-1", name: "Work", path: nil,
          launchers: [
            LauncherData(
              label: "Terminal", type: .applescript, command: "iTerm",
              appName: "iTerm", bundleID: "com.googlecode.iterm2")
          ])
      ],
      defaultNames: ["Work"])

    #expect(relocatedWindowIDs == [701])
    #expect(focusedWindowAttempts == 0)
  }

  @Test("AppleScript launcher failures are surfaced")
  func appleScriptLauncherFailuresAreSurfaced() {
    do {
      try WorkspaceLauncherExecutor.live.execute(
        WorkspaceLaunchRequest(
          steps: [.appleScript("error \"cold launch failed\" number 42")],
          bundleID: ""))
      Issue.record("Expected the failing AppleScript launcher to throw")
    } catch {
      #expect(error.localizedDescription.contains("cold launch failed"))
    }
  }
}
