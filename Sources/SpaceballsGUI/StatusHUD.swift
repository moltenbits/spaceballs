import Cocoa
import SwiftUI

/// A small floating HUD that shows a progress message on screen.
final class StatusHUD {
  private var panel: NSPanel?

  func show(message: String) {
    DispatchQueue.main.async { [self] in
      let panel = self.panel ?? createPanel()
      self.panel = panel

      let view = NSHostingView(rootView: StatusHUDView(message: message))
      panel.contentView = view
      view.layoutSubtreeIfNeeded()
      panel.setContentSize(view.fittingSize)

      // Center on the active screen
      let screen = NSScreen.main ?? NSScreen.screens.first!
      let screenFrame = screen.visibleFrame
      let panelSize = panel.frame.size
      let x = screenFrame.midX - panelSize.width / 2
      let y = screenFrame.midY - panelSize.height / 2 + screenFrame.height * 0.15
      panel.setFrameOrigin(NSPoint(x: x, y: y))
      panel.orderFrontRegardless()
    }
  }

  func dismiss() {
    DispatchQueue.main.async { [self] in
      panel?.orderOut(nil)
    }
  }

  private func createPanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero,
      styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.titlebarAppearsTransparent = true
    panel.titleVisibility = .hidden
    panel.isMovableByWindowBackground = false
    panel.hidesOnDeactivate = false
    panel.animationBehavior = .utilityWindow
    return panel
  }
}

private struct StatusHUDView: View {
  let message: String

  var body: some View {
    HStack(spacing: 10) {
      ProgressView()
        .controlSize(.small)
      Text(message)
        .font(.system(size: 13, weight: .medium))
        .lineLimit(2)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 14)
    .background(
      VibrancyBackground()
        .clipShape(RoundedRectangle(cornerRadius: 10))
    )
  }
}
