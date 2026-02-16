import Cocoa
import SpacebarGUILib
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var panel: SwitcherPanel!
  private var viewModel: SwitcherViewModel!
  private var keyInterceptor: KeyInterceptor!
  private var clickMonitor: Any?

  func applicationDidFinishLaunching(_ notification: Notification) {
    viewModel = SwitcherViewModel()

    let hostingView = NSHostingView(rootView: SwitcherView(viewModel: viewModel))

    panel = SwitcherPanel(contentRect: .zero)
    panel.contentView = hostingView

    keyInterceptor = KeyInterceptor()
    keyInterceptor.delegate = self
    keyInterceptor.start()

    // Dismiss on click outside the panel
    clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
      [weak self] event in
      guard let self, self.panel.isVisible else { return }
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

  // MARK: - Panel Management

  func showPanel() {
    viewModel.refresh()
    viewModel.resetSelection()
    resizePanelToFit()
    centerPanelOnActiveScreen()
    panel.makeKeyAndOrderFront(nil)
    keyInterceptor.setPanelVisible(true)
  }

  func hidePanel() {
    panel.orderOut(nil)
    keyInterceptor.setPanelVisible(false)
  }

  func activateAndDismiss() {
    hidePanel()
    viewModel.activateSelected()
  }

  // MARK: - Positioning

  private func resizePanelToFit() {
    guard let hostingView = panel.contentView as? NSHostingView<SwitcherView> else { return }
    let fittingSize = hostingView.fittingSize
    // Cap height to 80% of screen height to avoid overflowing
    let maxHeight = (NSScreen.main?.visibleFrame.height ?? 800) * 0.8
    let height = min(fittingSize.height, maxHeight)
    panel.setContentSize(NSSize(width: fittingSize.width, height: height))
  }

  private func centerPanelOnActiveScreen() {
    guard let screen = NSScreen.main else { return }
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
    activateAndDismiss()
  }

  func keyInterceptorCancel() {
    hidePanel()
  }
}
