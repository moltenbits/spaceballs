import Cocoa
import SwiftUI

final class SwitcherPanel: NSPanel {
  var displayUUID: String?
  private(set) var hostingView: NSHostingView<SwitcherView>?

  init(contentRect: NSRect) {
    super.init(
      contentRect: contentRect,
      styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )

    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    isOpaque = false
    backgroundColor = .clear
    titlebarAppearsTransparent = true
    titleVisibility = .hidden
    isMovableByWindowBackground = false
    hidesOnDeactivate = false
    animationBehavior = .utilityWindow
  }

  func setRootView(_ view: SwitcherView) {
    if let existing = hostingView {
      existing.rootView = view
    } else {
      let hv = NSHostingView(rootView: view)
      hostingView = hv
      contentView = hv
    }
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}
