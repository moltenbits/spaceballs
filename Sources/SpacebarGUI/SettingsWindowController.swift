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

    // Measure the tallest panes to size the window correctly.
    // Other panes fill the available space with top-aligned content.
    let contentWidth: CGFloat = 430  // 600 - 170 sidebar
    let measureAppearance = NSHostingView(
      rootView: AppearancePane(settings: appSettings)
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: contentWidth)
    )
    let measureShortcuts = NSHostingView(
      rootView: ShortcutsPane(settings: appSettings)
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: contentWidth)
    )
    let paneHeight = max(
      measureAppearance.fittingSize.height,
      measureShortcuts.fittingSize.height
    )
    let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
    let maxHeight = screenHeight * 0.8
    let initialHeight = min(max(paneHeight, 400), maxHeight)

    let win = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: initialHeight),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    win.title = "Spacebar Settings"
    win.contentView = hostingView
    win.contentMinSize = NSSize(width: 600, height: 400)
    win.contentMaxSize = NSSize(width: 600, height: maxHeight)
    win.center()
    win.isReleasedWhenClosed = false
    win.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    window = win
  }
}
