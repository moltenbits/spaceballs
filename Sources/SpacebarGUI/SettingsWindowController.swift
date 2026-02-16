import Cocoa
import SpacebarCore
import SpacebarGUILib
import SwiftUI

final class SettingsWindowController {
  private var window: NSWindow?
  private let spaceManager: SpaceManager
  private let spaceNameStore: SpaceNameStoring
  private let appSettings: AppSettings

  init(spaceManager: SpaceManager, spaceNameStore: SpaceNameStoring, appSettings: AppSettings) {
    self.spaceManager = spaceManager
    self.spaceNameStore = spaceNameStore
    self.appSettings = appSettings
  }

  func showSettings() {
    if let existing = window, existing.isVisible {
      existing.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    let settingsView = SettingsView(
      spaceManager: spaceManager,
      spaceNameStore: spaceNameStore,
      appSettings: appSettings
    )
    let hostingView = NSHostingView(rootView: settingsView)

    let win = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    win.title = "Spacebar Settings"
    win.contentView = hostingView
    win.contentMinSize = NSSize(width: 600, height: 400)
    win.contentMaxSize = NSSize(width: 600, height: 400)
    win.center()
    win.isReleasedWhenClosed = false
    win.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    window = win
  }
}
