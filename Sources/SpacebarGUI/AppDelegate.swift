import Cocoa
import SpacebarGUILib
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var panels: [SwitcherPanel] = []
  private var viewModel: SwitcherViewModel!
  private var keyInterceptor: KeyInterceptor!
  private var clickMonitor: Any?
  private var spaceNameStore: SpaceNameStore!
  private var appSettings: AppSettings!
  private var settingsController: SettingsWindowController!

  func applicationDidFinishLaunching(_ notification: Notification) {
    spaceNameStore = SpaceNameStore()
    appSettings = AppSettings()
    viewModel = SwitcherViewModel(spaceNameStore: spaceNameStore)

    panels = [makePanel()]

    settingsController = SettingsWindowController(
      spaceManager: viewModel.spaceManager,
      spaceNameStore: spaceNameStore,
      appSettings: appSettings
    )

    keyInterceptor = KeyInterceptor()
    keyInterceptor.delegate = self
    keyInterceptor.start()

    // Dismiss on click outside any panel
    clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
      [weak self] event in
      guard let self, self.panels.contains(where: \.isVisible) else { return }
      self.hidePanel()
    }

    print("Spacebar GUI running. Press Cmd+Tab to activate.")
  }

  func applicationWillTerminate(_ notification: Notification) {
    keyInterceptor.stop()
    if let monitor = clickMonitor {
      NSEvent.removeMonitor(monitor)
    }
  }

  // MARK: - Panel Factory

  private func makePanel() -> SwitcherPanel {
    let hostingView = NSHostingView(
      rootView: SwitcherView(viewModel: viewModel, appSettings: appSettings)
    )
    let panel = SwitcherPanel(contentRect: .zero)
    panel.contentView = hostingView
    return panel
  }

  // MARK: - Panel Management

  func showPanel() {
    viewModel.refresh()
    viewModel.resetSelection()

    let screens = targetScreens()

    // Ensure we have enough panels (lazily create extras for multi-display)
    while panels.count < screens.count {
      panels.append(makePanel())
    }

    // Show a panel on each target screen
    for (i, screen) in screens.enumerated() {
      let panel = panels[i]
      applyPanelAppearance(panel)
      resizePanelToFit(panel, on: screen)
      centerPanel(panel, on: screen)
      panel.makeKeyAndOrderFront(nil)
    }

    // Hide any extra panels from a previous show with more screens
    for i in screens.count..<panels.count {
      panels[i].orderOut(nil)
    }

    keyInterceptor.setPanelVisible(true)
  }

  func hidePanel() {
    for panel in panels {
      panel.orderOut(nil)
    }
    keyInterceptor.setPanelVisible(false)
  }

  func activateAndDismiss() {
    hidePanel()
    viewModel.activateSelected()
  }

  func openSettings() {
    hidePanel()
    settingsController.showSettings()
  }

  // MARK: - Panel Appearance

  private func applyPanelAppearance(_ panel: SwitcherPanel) {
    switch appSettings.colorScheme {
    case .auto:
      panel.appearance = nil
    case .light:
      panel.appearance = NSAppearance(named: .aqua)
    case .dark:
      panel.appearance = NSAppearance(named: .darkAqua)
    }
  }

  // MARK: - Display Targeting

  private func targetScreens() -> [NSScreen] {
    switch appSettings.panelDisplay {
    case .active:
      return [NSScreen.main ?? NSScreen.screens.first!]
    case .primary:
      return [NSScreen.screens.first!]
    case .all:
      return NSScreen.screens
    }
  }

  // MARK: - Positioning

  private func resizePanelToFit(_ panel: SwitcherPanel, on screen: NSScreen) {
    guard let hostingView = panel.contentView else { return }
    let fittingSize = hostingView.fittingSize
    let maxHeight = screen.visibleFrame.height * 0.8
    let height = min(fittingSize.height, maxHeight)
    panel.setContentSize(NSSize(width: fittingSize.width, height: height))
  }

  private func centerPanel(_ panel: SwitcherPanel, on screen: NSScreen) {
    let screenFrame = screen.visibleFrame
    let panelSize = panel.frame.size
    let x = screenFrame.midX - panelSize.width / 2
    let y = screenFrame.midY - panelSize.height / 2 + screenFrame.height * 0.1
    panel.setFrameOrigin(NSPoint(x: x, y: y))
  }
}

// MARK: - KeyInterceptorDelegate

extension AppDelegate: KeyInterceptorDelegate {
  func keyInterceptorReady() {
    if !CGPreflightScreenCaptureAccess() {
      CGRequestScreenCaptureAccess()
    }
  }

  func keyInterceptorShowPanel() {
    showPanel()
  }

  func keyInterceptorMoveDown() {
    viewModel.moveSelectionDown()
  }

  func keyInterceptorMoveUp() {
    viewModel.moveSelectionUp()
  }

  func keyInterceptorConfirm() {
    if viewModel.settingsSelected {
      openSettings()
    } else {
      activateAndDismiss()
    }
  }

  func keyInterceptorCancel() {
    hidePanel()
  }

  func keyInterceptorOpenSettings() {
    openSettings()
  }
}
