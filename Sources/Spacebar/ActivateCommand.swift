import ArgumentParser
import Cocoa
import SpacebarCore

struct ActivateCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "activate",
    abstract: "Activate (bring to front) a window by its ID"
  )

  @Argument(help: "The window ID to activate (from 'spacebar list')")
  var windowID: Int

  func run() throws {
    // Prefer delegating to the running GUI — same persistent process,
    // no new app launch, identical behavior to Cmd+Tab activation.
    if try delegateToRunningGUI() {
      return
    }

    // GUI not running — fall back to launching the CLI .app bundle.
    // Needed because _SLPSSetFrontProcessWithOptions requires a process
    // registered with WindowServer as a proper .app bundle.
    if AppBundleHelper.isRunningInAppBundle() {
      try runInAppBundle()
    } else {
      guard let appPath = AppBundleHelper.findInstalledAppBundle() else {
        fputs(
          "Error: Window activation requires either the Spacebar GUI to be running,\n",
          stderr)
        fputs(
          "or the Spacebar-CLI.app bundle installed (run 'make install').\n",
          stderr)
        throw ExitCode.failure
      }
      try AppBundleHelper.reexecViaApp(
        appPath: appPath, subcommand: "activate", args: [String(windowID)])
    }
  }

  // MARK: - Delegate to Running GUI

  /// Sends a distributed notification to the running GUI and waits for a reply.
  /// Returns true if the GUI handled it, false if the GUI isn't running.
  private func delegateToRunningGUI() throws -> Bool {
    let guiApps = NSRunningApplication.runningApplications(
      withBundleIdentifier: "com.moltenbits.spacebar"
    )
    guard !guiApps.isEmpty else { return false }

    let center = DistributedNotificationCenter.default()
    let replyName = "com.moltenbits.spacebar.cli.reply.\(UUID().uuidString)"
    let runLoop = CFRunLoopGetCurrent()

    var replyInfo: [String: Any]?

    let observer = center.addObserver(
      forName: Notification.Name(replyName),
      object: nil,
      queue: nil
    ) { notification in
      replyInfo = notification.userInfo as? [String: Any]
      CFRunLoopStop(runLoop)
    }

    // Timeout if GUI doesn't respond
    let timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
      CFRunLoopStop(runLoop)
    }

    center.postNotificationName(
      Notification.Name("com.moltenbits.spacebar.cli.activate"),
      object: nil,
      userInfo: ["windowID": windowID, "replyTo": replyName],
      deliverImmediately: true
    )

    CFRunLoopRun()
    timer.invalidate()
    center.removeObserver(observer)

    // Timeout — GUI didn't respond, fall back
    guard let reply = replyInfo else { return false }

    if let error = reply["error"] as? String {
      throw ValidationError(error)
    }

    return true
  }

  // MARK: - Direct Activation (inside .app bundle, GUI not running)

  private func runInAppBundle() throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()

    let manager = SpaceManager()
    try manager.activateWindow(id: windowID)

    // Brief pause for the background AX raise to complete.
    Thread.sleep(forTimeInterval: 0.2)
  }
}
