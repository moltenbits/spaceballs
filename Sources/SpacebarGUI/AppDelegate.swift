import Cocoa
import Combine
import SpacebarCore
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
  private var currentPanelDisplayUUID: String?
  private var cancellables = Set<AnyCancellable>()

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

    setupMainMenu()

    keyInterceptor = KeyInterceptor()
    keyInterceptor.delegate = self
    keyInterceptor.keyBindings = appSettings.keyBindings
    keyInterceptor.start()

    appSettings.$keyBindings
      .dropFirst()
      .sink { [weak self] newBindings in
        self?.keyInterceptor.keyBindings = newBindings
      }
      .store(in: &cancellables)

    appSettings.$isRecordingShortcut
      .dropFirst()
      .sink { [weak self] recording in
        self?.keyInterceptor.setRecordingMode(recording)
      }
      .store(in: &cancellables)

    viewModel.spaceManager.excludedBundleIDs = appSettings.excludedBundleIDs

    appSettings.$excludedBundleIDs
      .dropFirst()
      .sink { [weak self] ids in
        self?.viewModel.spaceManager.excludedBundleIDs = ids
      }
      .store(in: &cancellables)

    // Dismiss on click outside any panel
    clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
      [weak self] event in
      guard let self, self.panels.contains(where: \.isVisible) else { return }
      self.hidePanel()
    }

    // Listen for CLI commands via distributed notifications.
    // The CLI delegates to the running GUI so activation uses the same
    // persistent process — no new .app launch, no flicker, no z-order issues.
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(handleCLIActivate(_:)),
      name: Notification.Name("com.moltenbits.spacebar.cli.activate"),
      object: nil
    )

    print("Spacebar GUI running. Press Cmd+Tab to activate.")
  }

  // MARK: - CLI Bridge

  @objc private func handleCLIActivate(_ notification: Notification) {
    guard let userInfo = notification.userInfo as? [String: Any],
      let windowID = userInfo["windowID"] as? Int,
      let replyTo = userInfo["replyTo"] as? String
    else { return }

    let center = DistributedNotificationCenter.default()
    do {
      try viewModel.spaceManager.activateWindow(id: windowID)
      center.postNotificationName(
        Notification.Name(replyTo), object: nil,
        userInfo: ["success": true],
        deliverImmediately: true)
    } catch {
      center.postNotificationName(
        Notification.Name(replyTo), object: nil,
        userInfo: ["error": error.localizedDescription],
        deliverImmediately: true)
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    keyInterceptor.stop()
    if let monitor = clickMonitor {
      NSEvent.removeMonitor(monitor)
    }
  }

  // MARK: - Menu

  /// Accessory apps have no menu bar, so Cmd+W/Cmd+Q don't work by default.
  /// A minimal main menu provides the key equivalents for the Settings window.
  private func setupMainMenu() {
    let mainMenu = NSMenu()

    let appMenuItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(
      withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)),
      keyEquivalent: "w")
    appMenu.addItem(
      withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)),
      keyEquivalent: "q")
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)

    NSApp.mainMenu = mainMenu
  }

  /// Mode 3: filter enabled + panel on all displays.
  private var isMultiPanelPerDisplay: Bool {
    appSettings.filterSpacesByDisplay && appSettings.panelDisplay == .all
  }

  // MARK: - Panel Factory

  private func makePanel() -> SwitcherPanel {
    SwitcherPanel(contentRect: .zero)
  }

  // MARK: - Panel Management

  func showPanel() {
    viewModel.overrideDisplayUUID = nil
    viewModel.showEmptySpaces = appSettings.showEmptySpaces

    let multiPanel = isMultiPanelPerDisplay
    let screens = targetScreens()
    let activeScreen = NSScreen.main ?? NSScreen.screens.first!
    let activeUUID = Self.displayUUID(for: activeScreen)

    // Mode 3: no ViewModel-level filter; each view filters its own display.
    // Mode 2: ViewModel filters to the focused display.
    // Mode 1: no filter.
    viewModel.filterByDisplay = appSettings.filterSpacesByDisplay && !multiPanel
    viewModel.spaceSortOrder = appSettings.spaceSortOrder

    if multiPanel {
      // Build display order: active display first, then the rest in screen order
      var order: [String] = []
      if let uuid = activeUUID { order.append(uuid) }
      for screen in NSScreen.screens {
        if let uuid = Self.displayUUID(for: screen), !order.contains(uuid) {
          order.append(uuid)
        }
      }
      viewModel.displayOrder = order
    } else {
      viewModel.displayOrder = []
    }

    viewModel.refresh()
    viewModel.resetSelection()

    // Ensure we have enough panels
    while panels.count < screens.count {
      panels.append(makePanel())
    }

    // Set up root views and show panels
    for (i, screen) in screens.enumerated() {
      let panel = panels[i]
      let panelUUID = Self.displayUUID(for: screen)
      panel.displayUUID = panelUUID

      let rootView = SwitcherView(
        viewModel: viewModel,
        appSettings: appSettings,
        displayUUID: multiPanel ? panelUUID : nil
      )
      panel.setRootView(rootView)
      applyPanelAppearance(panel)

      // Initial size — will be corrected after the first layout settles.
      _ = resizePanelToFit(panel, on: screen)
      centerPanel(panel, on: screen)

      if panelUUID == activeUUID {
        panel.makeKeyAndOrderFront(nil)
      } else {
        panel.orderFront(nil)
      }
    }

    // Hide extra panels from a previous show
    for i in screens.count..<panels.count {
      panels[i].orderOut(nil)
      panels[i].displayUUID = nil
    }

    currentPanelDisplayUUID = activeUUID
    keyInterceptor.setPanelVisible(true)

    // Deferred re-size: NSHostingView needs a run loop cycle to settle SwiftUI
    // layout on the first render. Re-measure and apply overflow indicators.
    DispatchQueue.main.async { [self, screens, multiPanel] in
      for (i, screen) in screens.enumerated() {
        let panel = panels[i]
        let (overflows, panelHeight) = resizePanelToFit(panel, on: screen)
        if overflows {
          let rowHeight = max(appSettings.textSize + 8, 20)
          let capacity = Int(panelHeight / rowHeight)
          let updatedView = SwitcherView(
            viewModel: viewModel,
            appSettings: appSettings,
            displayUUID: multiPanel ? panel.displayUUID : nil,
            contentOverflows: true,
            visibleCapacity: capacity
          )
          panel.setRootView(updatedView)
        }
        centerPanel(panel, on: screen)
      }
    }
  }

  func hidePanel() {
    if viewModel.isRenaming {
      viewModel.cancelRename()
      keyInterceptor.setRenameMode(false)
    }
    for panel in panels {
      panel.orderOut(nil)
      panel.displayUUID = nil
    }
    currentPanelDisplayUUID = nil
    viewModel.overrideDisplayUUID = nil
    viewModel.displayOrder = []
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

  private static func displayUUID(for screen: NSScreen) -> String? {
    guard
      let screenNumber = screen.deviceDescription[
        NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    else { return nil }
    let cfUUID = CGDisplayCreateUUIDFromDisplayID(screenNumber)?.takeUnretainedValue()
    guard let cfUUID else { return nil }
    return CFUUIDCreateString(nil, cfUUID) as String
  }

  private func cycleDisplay(forward: Bool) {
    guard appSettings.filterSpacesByDisplay else { return }
    let screens = NSScreen.screens
    guard screens.count > 1 else { return }

    if isMultiPanelPerDisplay {
      // Mode 3: move selection to next/previous display's first window
      // and make that panel the key window.
      let order = viewModel.displayOrder
      guard order.count > 1 else { return }
      let currentUUID = viewModel.activeDisplayUUID ?? order.first ?? ""
      let currentIdx = order.firstIndex(of: currentUUID) ?? 0
      let nextIdx =
        forward
        ? (currentIdx + 1) % order.count
        : (currentIdx - 1 + order.count) % order.count
      let targetUUID = order[nextIdx]
      viewModel.selectFirstWindow(onDisplay: targetUUID)

      // Move key window to the target panel
      if let targetPanel = panels.first(where: { $0.displayUUID == targetUUID }) {
        targetPanel.makeKeyAndOrderFront(nil)
      }
      currentPanelDisplayUUID = targetUUID
    } else {
      // Mode 2: single panel, cycle display content
      let currentIndex =
        screens.firstIndex(where: {
          Self.displayUUID(for: $0) == currentPanelDisplayUUID
        }) ?? 0

      let nextIndex =
        forward
        ? (currentIndex + 1) % screens.count
        : (currentIndex - 1 + screens.count) % screens.count
      let targetScreen = screens[nextIndex]

      let targetUUID = Self.displayUUID(for: targetScreen)
      viewModel.overrideDisplayUUID = targetUUID
      viewModel.refresh()
      viewModel.resetSelection()

      let panel = panels[0]
      _ = resizePanelToFit(panel, on: targetScreen)
      centerPanel(panel, on: targetScreen)
      currentPanelDisplayUUID = targetUUID
    }
  }

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

  /// Returns (overflows, panelHeight).
  private func resizePanelToFit(_ panel: SwitcherPanel, on screen: NSScreen) -> (Bool, CGFloat) {
    guard let hostingView = panel.contentView else { return (false, 0) }
    hostingView.layoutSubtreeIfNeeded()
    let fittingSize = hostingView.fittingSize
    let maxHeight = screen.visibleFrame.height * 0.8
    let overflows = fittingSize.height > maxHeight
    let height = min(fittingSize.height, maxHeight)
    panel.setContentSize(NSSize(width: fittingSize.width, height: height))
    return (overflows, height)
  }

  private func centerPanel(_ panel: SwitcherPanel, on screen: NSScreen) {
    let screenFrame = screen.visibleFrame
    let panelSize = panel.frame.size
    let x = screenFrame.midX - panelSize.width / 2
    // Slight upward bias that fades as the panel fills the screen.
    let fillRatio = panelSize.height / screenFrame.height
    let upwardBias = screenFrame.height * 0.1 * max(1 - fillRatio, 0)
    let y = screenFrame.midY - panelSize.height / 2 + upwardBias
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
    switch viewModel.selectedItem {
    case .settings:
      openSettings()
    case .spaceHeader, .windowRow:
      activateAndDismiss()
    case nil:
      break
    }
  }

  func keyInterceptorCancel() {
    hidePanel()
  }

  func keyInterceptorCloseWindow() {
    viewModel.closeSelectedWindow()
  }

  func keyInterceptorQuitApp() {
    viewModel.quitSelectedApp()
  }

  func keyInterceptorOpenSettings() {
    openSettings()
  }

  func keyInterceptorCycleDisplayLeft() {
    cycleDisplay(forward: false)
  }

  func keyInterceptorCycleDisplayRight() {
    cycleDisplay(forward: true)
  }

  func keyInterceptorJumpToNextSpace() {
    viewModel.moveToNextSpace()
  }

  func keyInterceptorJumpToPreviousSpace() {
    viewModel.moveToPreviousSpace()
  }

  func keyInterceptorStartRename() {
    guard viewModel.canRenameFromCurrentSelection else { return }
    viewModel.startRenaming()
    guard viewModel.isRenaming else { return }
    keyInterceptor.setRenameMode(true)
  }

  func keyInterceptorCycleSortOrder() {
    viewModel.cycleSortOrder()
    appSettings.spaceSortOrder = viewModel.spaceSortOrder

    // Resize panels after sort may change content
    let screens = targetScreens()
    for (i, screen) in screens.enumerated() where i < panels.count {
      _ = resizePanelToFit(panels[i], on: screen)
      centerPanel(panels[i], on: screen)
    }
  }

  func keyInterceptorCreateDefaultSpaces() {
    let names = appSettings.customSpaceNames
    guard !names.isEmpty else {
      viewModel.sortOverlayText = "No default spaces defined"
      viewModel.sortOverlayGeneration += 1
      return
    }

    // Prune stale name mappings for deleted spaces
    let currentUUIDs = Set(viewModel.spaceManager.getAllSpaces().map(\.uuid))
    for (uuid, _) in viewModel.spaceNameStore.allCustomNames() where !currentUUIDs.contains(uuid) {
      viewModel.spaceNameStore.setCustomName(nil, forSpaceUUID: uuid)
    }

    let existingNames = Set(viewModel.spaceNameStore.allCustomNames().values)
    let missingNames = names.filter { !existingNames.contains($0) }

    guard !missingNames.isEmpty else {
      viewModel.sortOverlayText = "All default spaces already exist"
      viewModel.sortOverlayGeneration += 1
      return
    }

    viewModel.sortOverlayText = "Creating \(missingNames.count) space\(missingNames.count == 1 ? "" : "s")..."
    viewModel.sortOverlayGeneration += 1

    viewModel.createDefaultSpaces(defaultNames: names) { [weak self] created in
      guard let self else { return }
      if created > 0 {
        self.viewModel.sortOverlayText = "Created \(created) space\(created == 1 ? "" : "s")"
      } else {
        self.viewModel.sortOverlayText = "All default spaces already exist"
      }
      self.viewModel.sortOverlayGeneration += 1
      self.viewModel.refresh()
      self.viewModel.resetSelection()

      // Resize panels to fit new content
      DispatchQueue.main.async {
        let screens = self.targetScreens()
        for (i, screen) in screens.enumerated() where i < self.panels.count {
          _ = self.resizePanelToFit(self.panels[i], on: screen)
          self.centerPanel(self.panels[i], on: screen)
        }
      }
    }
  }

  func keyInterceptorCommitRename() {
    viewModel.commitRename()
    keyInterceptor.setRenameMode(false)
  }

  func keyInterceptorCancelRename() {
    viewModel.cancelRename()
    keyInterceptor.setRenameMode(false)
  }
}
