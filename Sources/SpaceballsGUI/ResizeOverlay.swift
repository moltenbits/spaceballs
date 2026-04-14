import Cocoa
import SpaceballsCore
import SpaceballsGUILib
import SwiftUI

/// A full-screen transparent overlay that shows the resize grid on the display.
final class ResizeOverlay {
  private var panel: NSPanel?
  private var hostingView: NSHostingView<ResizeOverlayView>?

  func show(
    on screen: NSScreen, viewModel: ResizeViewModel, settings: AppSettings,
    displayUUID: String?
  ) {
    let panel = self.panel ?? createPanel()
    self.panel = panel

    let view = ResizeOverlayView(viewModel: viewModel, settings: settings, displayUUID: displayUUID)
    if let existing = hostingView {
      existing.rootView = view
    } else {
      let hv = NSHostingView(rootView: view)
      hostingView = hv
      panel.contentView = hv
    }

    // Cover the screen's visible frame (excluding menu bar and dock)
    panel.setFrame(screen.visibleFrame, display: true)
    panel.orderFront(nil)
  }

  func dismiss() {
    panel?.orderOut(nil)
  }

  func updateScreen(_ screen: NSScreen) {
    panel?.setFrame(screen.visibleFrame, display: true)
  }

  private func createPanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero,
      styleMask: [.nonactivatingPanel, .borderless],
      backing: .buffered,
      defer: false
    )
    // Below .floating so the resize grid panel appears on top
    panel.level = NSWindow.Level(Int(CGWindowLevelForKey(.floatingWindow)) - 1)
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.animationBehavior = .none
    return panel
  }
}

// MARK: - Overlay SwiftUI View

struct ResizeOverlayView: View {
  @ObservedObject var viewModel: ResizeViewModel
  @ObservedObject var settings: AppSettings
  let displayUUID: String?

  private var isTargetDisplay: Bool {
    displayUUID == viewModel.targetDisplayUUID
  }

  private var columns: Int {
    viewModel.previewRegion?.gridColumns
      ?? viewModel.activeRegion?.gridColumns
      ?? settings.resizeGridColumns
  }

  private var rows: Int {
    viewModel.previewRegion?.gridRows
      ?? viewModel.activeRegion?.gridRows
      ?? settings.resizeGridRows
  }

  private var highlightRegion: GridRegion? {
    guard isTargetDisplay else { return nil }
    return viewModel.previewRegion ?? viewModel.activeRegion
  }

  var body: some View {
    Canvas { context, size in
      let cellW = size.width / CGFloat(columns)
      let cellH = size.height / CGFloat(rows)

      // Draw grid lines
      for col in 0...columns {
        let x = CGFloat(col) * cellW
        var path = Path()
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(path, with: .color(.white.opacity(0.15)), lineWidth: 1)
      }
      for row in 0...rows {
        let y = CGFloat(row) * cellH
        var path = Path()
        path.move(to: CGPoint(x: 0, y: y))
        path.addLine(to: CGPoint(x: size.width, y: y))
        context.stroke(path, with: .color(.white.opacity(0.15)), lineWidth: 1)
      }

      // Draw highlighted region
      if let region = highlightRegion {
        let x = CGFloat(region.column) * cellW
        let y = CGFloat(region.row) * cellH
        let w = CGFloat(region.columnSpan) * cellW
        let h = CGFloat(region.rowSpan) * cellH
        let rect = CGRect(x: x, y: y, width: w, height: h)
        context.fill(
          RoundedRectangle(cornerRadius: 4).path(in: rect),
          with: .color(.accentColor.opacity(0.25))
        )
        context.stroke(
          RoundedRectangle(cornerRadius: 4).path(in: rect.insetBy(dx: 0.5, dy: 0.5)),
          with: .color(.accentColor.opacity(0.6)),
          lineWidth: 2
        )
      }
    }
  }
}
