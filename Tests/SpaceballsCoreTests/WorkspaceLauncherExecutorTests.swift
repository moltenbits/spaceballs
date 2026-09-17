import Foundation
import Testing

@testable import SpaceballsCore

@Suite("Workspace Launcher Execution")
struct WorkspaceLauncherExecutorTests {
  @Test("Real shell failures retain their exit status and stop later commands")
  func realShellFailure() {
    do {
      try WorkspaceLauncherExecutor.live.execute(
        WorkspaceLaunchRequest(
          steps: [.shell("exit 7"), .shell("exit 9")], bundleID: ""))
      Issue.record("Expected a shell failure")
    } catch WorkspaceLauncherError.processFailed(let type, let status, _) {
      #expect(type == "shell")
      #expect(status == 7)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test("Shell preparation completes before later steps")
  func shellPreparationWaits() throws {
    var prepared = false
    let executor = WorkspaceLauncherExecutor(
      runProcess: { _, _, waits in
        #expect(waits)
        prepared = waits
      },
      openWithLaunchServices: { _ in #expect(prepared) })
    try executor.execute(
      WorkspaceLaunchRequest(
        steps: [.shell("prepare-project"), .launchServices(.init())], bundleID: "example.App"))
  }

  @Test("A failed synchronous shell step stops the pipeline")
  func shellFailureStopsPipeline() {
    var opened = false
    let executor = WorkspaceLauncherExecutor(
      runProcess: { _, _, waits in
        if waits { throw TestError.launchFailed }
      },
      openWithLaunchServices: { _ in opened = true })
    #expect(throws: TestError.self) {
      try executor.execute(
        WorkspaceLaunchRequest(
          steps: [.shell("exit 1"), .launchServices(.init())], bundleID: "example.App"))
    }
    #expect(!opened)
  }

  @Test("Composed launchers execute each typed step in order")
  func composedLauncherOrder() throws {
    var events: [String] = []
    let executor = WorkspaceLauncherExecutor(
      runProcess: { executable, arguments, waitsForExit in
        events.append(executable.lastPathComponent)
        #expect(arguments == ["-e", "tell application \"iTerm\" to activate"])
        #expect(waitsForExit)
      },
      openWithLaunchServices: { request in
        events.append("launch-services")
        #expect(request.bundleID == "com.googlecode.iterm2")
        #expect(request.target == nil)
      })

    try executor.execute(
      WorkspaceLaunchRequest(
        steps: [
          .launchServices(WorkspaceLaunchServicesConfiguration()),
          .appleScript("tell application \"iTerm\" to activate"),
        ],
        bundleID: "com.googlecode.iterm2"))

    #expect(events == ["launch-services", "osascript"])
  }

  @Test("Launch Services receives arguments, environment, and instance policy")
  func launchServicesConfiguration() throws {
    var captured: WorkspaceLaunchServicesRequest?
    let executor = WorkspaceLauncherExecutor(
      runProcess: { _, _, _ in },
      openWithLaunchServices: { captured = $0 })

    try executor.execute(
      WorkspaceLaunchRequest(
        steps: [
          .launchServices(
            WorkspaceLaunchServicesConfiguration(
              target: "/Users/example/Project",
              arguments: ["--line", "42"],
              environment: [
                WorkspaceEnvironmentVariable(name: "PROJECT", value: "/Users/example/Project"),
                WorkspaceEnvironmentVariable(name: "EMPTY_KEY_IS_IGNORED", value: "first"),
                WorkspaceEnvironmentVariable(name: "", value: "ignored"),
                WorkspaceEnvironmentVariable(name: "EMPTY_KEY_IS_IGNORED", value: "last"),
              ],
              createsNewApplicationInstance: true,
              activates: false))
        ],
        bundleID: "com.example.Editor"))

    guard let captured else {
      Issue.record("Expected the Launch Services request")
      return
    }
    #expect(captured.bundleID == "com.example.Editor")
    #expect(captured.target?.path == "/Users/example/Project")
    #expect(captured.arguments == ["--line", "42"])
    #expect(
      captured.environment == [
        "PROJECT": "/Users/example/Project", "EMPTY_KEY_IS_IGNORED": "last",
      ])
    #expect(captured.createsNewApplicationInstance)
    #expect(!captured.activates)

    let openConfiguration = WorkspaceLauncherExecutor.openConfiguration(for: captured)
    #expect(openConfiguration.arguments == ["--line", "42"])
    #expect(
      openConfiguration.environment == [
        "PROJECT": "/Users/example/Project", "EMPTY_KEY_IS_IGNORED": "last",
      ])
    #expect(openConfiguration.createsNewApplicationInstance)
    #expect(!openConfiguration.activates)
  }

  @Test("Launch Services preserves activating open configurations")
  func activatingLaunchServicesConfiguration() throws {
    var captured: WorkspaceLaunchServicesRequest?
    let executor = WorkspaceLauncherExecutor(
      runProcess: { _, _, _ in },
      openWithLaunchServices: { captured = $0 })

    try executor.execute(
      WorkspaceLaunchRequest(
        steps: [
          .launchServices(WorkspaceLaunchServicesConfiguration(activates: true))
        ],
        bundleID: "com.example.Editor"))

    guard let captured else {
      Issue.record("Expected the Launch Services request")
      return
    }
    #expect(captured.activates)
    #expect(WorkspaceLauncherExecutor.openConfiguration(for: captured).activates)
  }

  @Test("Launch Services drops empty arguments before opening the application")
  func launchServicesDropsEmptyArguments() throws {
    var captured: WorkspaceLaunchServicesRequest?
    let executor = WorkspaceLauncherExecutor(
      runProcess: { _, _, _ in },
      openWithLaunchServices: { captured = $0 })

    try executor.execute(
      WorkspaceLaunchRequest(
        steps: [
          .launchServices(
            WorkspaceLaunchServicesConfiguration(arguments: ["--workspace", "", "project", ""]))
        ],
        bundleID: "com.example.Editor"))

    #expect(captured?.arguments == ["--workspace", "project"])
  }

  @Test("Launch Services opens a file target with the configured bundle")
  func launchServicesOpensTarget() throws {
    var processCalls: [ProcessCall] = []
    var launchCalls: [WorkspaceLaunchServicesRequest] = []
    let executor = WorkspaceLauncherExecutor(
      runProcess: { executable, arguments, waitsForExit in
        processCalls.append(
          ProcessCall(
            executable: executable, arguments: arguments,
            waitsForExit: waitsForExit))
      },
      openWithLaunchServices: { launchCalls.append($0) })

    try executor.execute(
      WorkspaceLaunchRequest(
        steps: [
          .launchServices(
            WorkspaceLaunchServicesConfiguration(target: "/Users/example/My Project"))
        ],
        bundleID: "com.jetbrains.intellij"))

    #expect(processCalls.isEmpty)
    #expect(launchCalls.count == 1)
    #expect(launchCalls.first?.bundleID == "com.jetbrains.intellij")
    #expect(launchCalls.first?.target?.isFileURL == true)
    #expect(launchCalls.first?.target?.path == "/Users/example/My Project")
  }

  @Test("Launch Services launches an app when the target is empty")
  func launchServicesOpensApplication() throws {
    var launchCalls: [WorkspaceLaunchServicesRequest] = []
    let executor = WorkspaceLauncherExecutor(
      runProcess: { _, _, _ in },
      openWithLaunchServices: { launchCalls.append($0) })

    try executor.execute(
      WorkspaceLaunchRequest(
        steps: [.launchServices(WorkspaceLaunchServicesConfiguration())],
        bundleID: "com.apple.TextEdit"))

    #expect(launchCalls.count == 1)
    #expect(launchCalls.first?.bundleID == "com.apple.TextEdit")
    #expect(launchCalls.first?.target == nil)
  }

  @Test("Launch Services preserves URL targets")
  func launchServicesOpensURL() throws {
    var target: URL?
    let executor = WorkspaceLauncherExecutor(
      runProcess: { _, _, _ in },
      openWithLaunchServices: { target = $0.target })

    try executor.execute(
      WorkspaceLaunchRequest(
        steps: [
          .launchServices(
            WorkspaceLaunchServicesConfiguration(target: "https://example.com/project"))
        ],
        bundleID: "com.apple.Safari"))

    #expect(target?.absoluteString == "https://example.com/project")
  }

  @Test("AppleScript steps do not hide an implicit application launch")
  func appleScriptHasNoImplicitLaunch() throws {
    var processRan = false
    let executor = WorkspaceLauncherExecutor(
      runProcess: { executable, arguments, waitsForExit in
        processRan = true
        #expect(executable.path == "/usr/bin/osascript")
        #expect(arguments == ["-e", "tell application \"iTerm\" to activate"])
        #expect(waitsForExit)
      },
      openWithLaunchServices: { _ in
        Issue.record("AppleScript must launch an app only through an explicit prior step")
      })

    try executor.execute(
      WorkspaceLaunchRequest(
        steps: [.appleScript("tell application \"iTerm\" to activate")],
        bundleID: "com.googlecode.iterm2"))

    #expect(processRan)
  }

  @Test("Generic AppleScripts run without requiring an application bundle")
  func genericAppleScript() throws {
    var processCalls: [ProcessCall] = []
    var launched = false
    let executor = WorkspaceLauncherExecutor(
      runProcess: { executable, arguments, waitsForExit in
        processCalls.append(
          ProcessCall(
            executable: executable, arguments: arguments,
            waitsForExit: waitsForExit))
      },
      openWithLaunchServices: { _ in launched = true })

    try executor.execute(
      WorkspaceLaunchRequest(
        steps: [.appleScript("display dialog \"Hello\"")], bundleID: ""))

    #expect(!launched)
    #expect(processCalls.count == 1)
    #expect(processCalls.first?.executable.path == "/usr/bin/osascript")
    #expect(processCalls.first?.arguments == ["-e", "display dialog \"Hello\""])
    #expect(processCalls.first?.waitsForExit == true)
  }

  @Test("Shell launchers remain fire-and-forget")
  func shellLauncher() throws {
    var processCall: ProcessCall?
    let executor = WorkspaceLauncherExecutor(
      runProcess: { executable, arguments, waitsForExit in
        processCall = ProcessCall(
          executable: executable, arguments: arguments,
          waitsForExit: waitsForExit)
      },
      openWithLaunchServices: { _ in
        Issue.record("Shell launchers must not invoke Launch Services")
      })

    try executor.execute(
      WorkspaceLaunchRequest(
        steps: [.shell("echo hello", waitsForExit: false)], bundleID: ""))

    #expect(processCall?.executable.path == "/bin/zsh")
    #expect(processCall?.arguments == ["-c", "echo hello"])
    #expect(processCall?.waitsForExit == false)
  }

  @Test(
    "Open launchers pass application names and selected paths as one argument",
    arguments: ["Preview", "/Applications/An App's Name.app"])
  func openLauncher(application: String) throws {
    var processCall: ProcessCall?
    let executor = WorkspaceLauncherExecutor(
      runProcess: { executable, arguments, waitsForExit in
        processCall = ProcessCall(
          executable: executable, arguments: arguments,
          waitsForExit: waitsForExit)
      },
      openWithLaunchServices: { _ in
        Issue.record("Legacy open launchers use the open command")
      })

    try executor.execute(
      WorkspaceLaunchRequest(steps: [.openApplication(application)], bundleID: ""))

    #expect(processCall?.executable.path == "/usr/bin/open")
    #expect(processCall?.arguments == ["-a", application])
    #expect(processCall?.waitsForExit == true)
  }

  @Test(
    "Selected apps fall back to bundle identity only when their path is gone",
    arguments: [true, false])
  func selectedAppRelocation(pathExists: Bool) throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".app")
    if pathExists {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: url) }
    var arguments: [String]?
    let executor = WorkspaceLauncherExecutor(
      runProcess: { _, args, _ in arguments = args },
      openWithLaunchServices: { _ in Issue.record("Expected an Open App step") })
    try executor.execute(
      WorkspaceLaunchRequest(steps: [.openApplication(url.path)], bundleID: "example.selected"))
    #expect(arguments == (pathExists ? ["-a", url.path] : ["-b", "example.selected"]))
  }

  @Test("Launch Services requires an application bundle")
  func launchServicesRequiresBundleID() {
    let executor = WorkspaceLauncherExecutor(
      runProcess: { _, _, _ in },
      openWithLaunchServices: { _ in })

    #expect(throws: WorkspaceLauncherError.self) {
      try executor.execute(
        WorkspaceLaunchRequest(
          steps: [
            .launchServices(WorkspaceLaunchServicesConfiguration(target: "/tmp"))
          ],
          bundleID: ""))
    }
  }

  @Test("A failed step stops the remaining composition")
  func failedStepStopsComposition() {
    var processRan = false
    let executor = WorkspaceLauncherExecutor(
      runProcess: { _, _, _ in processRan = true },
      openWithLaunchServices: { _ in throw TestError.launchFailed })

    #expect(throws: TestError.self) {
      try executor.execute(
        WorkspaceLaunchRequest(
          steps: [
            .launchServices(WorkspaceLaunchServicesConfiguration()),
            .appleScript("display dialog \"must not run\""),
          ],
          bundleID: "com.example.App"))
    }
    #expect(!processRan)
  }

  @Test("An empty composition is rejected")
  func emptyCompositionIsRejected() {
    let executor = WorkspaceLauncherExecutor(
      runProcess: { _, _, _ in },
      openWithLaunchServices: { _ in })

    #expect(throws: WorkspaceLauncherError.self) {
      try executor.execute(WorkspaceLaunchRequest(steps: [], bundleID: ""))
    }
  }

  private enum TestError: Error {
    case launchFailed
  }

  private struct ProcessCall {
    let executable: URL
    let arguments: [String]
    let waitsForExit: Bool
  }
}
