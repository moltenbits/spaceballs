import Cocoa
import Combine
import SpaceballsCore
import SpaceballsGUILib
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
  private var resizePanels: [ResizePanel] = []
  private var resizeViewModel: ResizeViewModel!
  private var resizeOverlays: [ResizeOverlay] = []
  private var cancellables = Set<AnyCancellable>()
  var windowLayoutStore: WindowLayoutStore!
  private var windowLayoutCoordinator: WindowLayoutCoordinator!
  private let ejectStore = EjectStore()
  private let progressOverlay = ProgressOverlay()
  private let mouseBlocker = MouseInputBlocker()
  private lazy var spaceTransferShield = SpaceTransferShield(
    mouseInputBlocker: mouseBlocker,
    shortcutBlocker: keyInterceptor,
    overlay: progressOverlay)
  /// One eject, display restore, or workspace setup at a time. These operations
  /// share the overlay and may all drive Mission Control.
  private var spaceEvacuationInFlight = false
  private var pendingRestoreWork: DispatchWorkItem?
  private var restoreFailedAttempts = 0
  private let restoreRetryPolicy = RestoreRetryPolicy()
  private var permissionsCoordinator: PermissionsCoordinator!
  private var permissionsGrantTimer: Timer?

  func applicationDidBecomeActive(_ notification: Notification) {
    permissionsCoordinator?.checkAndPrompt()
  }

  /// Relaunches the app: spawns a detached shell that waits for this process
  /// to exit, then reopens the bundle, and terminates. Used after a Screen
  /// Recording grant, which only applies to a fresh process.
  private static func relaunchFromBundle() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
      "-c", "sleep 1.5; /usr/bin/open \"\(Bundle.main.bundlePath)\"",
    ]
    try? process.run()
    NSApp.terminate(nil)
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    // Fires when the user launches the app while it's already running — the
    // natural recovery gesture when the hotkey is dead because a permission
    // is missing. Re-check and prompt right away.
    permissionsCoordinator?.checkAndPrompt()
    return true
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    spaceNameStore = SpaceNameStore()
    appSettings = AppSettings()
    viewModel = SwitcherViewModel(spaceNameStore: spaceNameStore)

    panels = [makePanel()]
    resizeViewModel = ResizeViewModel()

    windowLayoutStore = WindowLayoutStore(
      spaceManager: viewModel.spaceManager,
      spaceNameStore: spaceNameStore)
    windowLayoutCoordinator = WindowLayoutCoordinator(
      store: windowLayoutStore,
      spaceManager: viewModel.spaceManager,
      spaceNameStore: spaceNameStore,
      appSettings: appSettings
    )
    windowLayoutCoordinator.start()

    settingsController = SettingsWindowController(
      spaceManager: viewModel.spaceManager,
      spaceNameStore: spaceNameStore,
      appSettings: appSettings,
      windowLayoutStore: windowLayoutStore
    )

    setupMainMenu()

    assignDefaultSpaceNames()
    armEjectionRecords()

    keyInterceptor = KeyInterceptor()
    keyInterceptor.delegate = self
    keyInterceptor.keyBindings = appSettings.keyBindings
    keyInterceptor.tapLocation = appSettings.eventTapLocation
    keyInterceptor.start()

    // Check permissions at launch and prompt for anything missing. Re-checked on
    // every activation/reopen (see applicationDidBecomeActive / ShouldHandleReopen)
    // so a lost grant — e.g. a TCC reset after the app is re-signed — is surfaced
    // immediately instead of the hotkey and window titles failing silently.
    permissionsCoordinator = PermissionsCoordinator(
      isAccessibilityTrusted: { AXIsProcessTrusted() },
      promptAccessibility: { SpaceManager.ensureAccessibilityTrusted() },
      hasScreenRecording: { CGPreflightScreenCaptureAccess() },
      promptScreenRecording: { CGRequestScreenCaptureAccess() }
    )
    permissionsCoordinator.checkAndPrompt()

    // A Screen Recording grant only takes effect on a fresh WindowServer
    // connection, and the system's "Quit & Reopen" reliably quits but often
    // never reopens. Watch for the grant and relaunch ourselves instead.
    permissionsGrantTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) {
      [weak self] _ in
      guard let self, self.permissionsCoordinator.didScreenRecordingJustBecomeGranted() else {
        return
      }
      self.permissionsGrantTimer?.invalidate()
      self.permissionsGrantTimer = nil
      self.progressOverlay.show(message: "Screen Recording granted — restarting Spaceballs…")
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
        Self.relaunchFromBundle()
      }
    }

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

    appSettings.$captureRemoteInput
      .dropFirst()
      .sink { [weak self] capture in
        self?.keyInterceptor.updateTapLocation(
          capture ? .cgSessionEventTap : .cghidEventTap)
      }
      .store(in: &cancellables)

    viewModel.spaceManager.excludedBundleIDs = appSettings.excludedBundleIDs

    appSettings.$excludedBundleIDs
      .dropFirst()
      .sink { [weak self] ids in
        self?.viewModel.spaceManager.excludedBundleIDs = ids
      }
      .store(in: &cancellables)

    // Mode 3: keyboard input routes to the key window, so the panel showing
    // the selection must be key — otherwise inline rename types into a panel
    // with no focused field and every keystroke beeps. `$selectedItem` emits
    // on willSet, so the emitted value is passed rather than re-read.
    viewModel.$selectedItem
      .sink { [weak self] item in
        self?.syncKeyPanel(toSelection: item)
      }
      .store(in: &cancellables)

    viewModel.spaceManager.moveTiming = appSettings.moveTiming

    Publishers.CombineLatest3(
      appSettings.$timingSpaceSwitchSettle,
      appSettings.$timingDropSettle,
      appSettings.$timingBetweenDrags
    )
    .dropFirst()
    .sink { [weak self] settle, drop, between in
      self?.viewModel.spaceManager.moveTiming = SpaceMoveTiming(
        preSwitchSettle: settle, dropSettle: drop, interDragPause: between)
    }
    .store(in: &cancellables)

    // Dismiss on click outside any panel
    clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
      [weak self] event in
      guard let self else { return }
      if self.resizePanels.contains(where: \.isVisible) {
        self.hideResizePanel()
      }
      if self.panels.contains(where: \.isVisible) {
        self.hidePanel()
      }
    }

    // Listen for CLI commands via distributed notifications.
    // The CLI delegates to the running GUI so activation uses the same
    // persistent process — no new .app launch, no flicker, no z-order issues.
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(handleCLIActivate(_:)),
      name: Notification.Name("com.moltenbits.spaceballs.cli.activate"),
      object: nil
    )

    // Diagnostics: write a header at launch (if enabled) and re-dump on display
    // reconfig so the log always has fresh context to correlate against.
    if Diagnostics.enabled {
      Diagnostics.writeHeader(
        appVersion: appVersionString, spaceManager: viewModel.spaceManager)
    }
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil, queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      Diagnostics.log("display", "didChangeScreenParameters fired")
      // CGS lags screen-parameters notifications on some macOS versions; brief delay
      // before re-snapshotting so the dumped state matches what the user sees.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        Diagnostics.writeHeader(
          appVersion: self.appVersionString, spaceManager: self.viewModel.spaceManager)
        self.assignDefaultSpaceNames()
        self.armEjectionRecords()
      }
      self.scheduleEjectionRestore()
    }

    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification,
      object: nil, queue: .main
    ) { _ in
      Diagnostics.log("space", "activeSpaceDidChange fired")
    }

    print("Spaceballs GUI running. Press Cmd+Tab to activate.")
  }

  /// "1.0.0 (5)" — used in diagnostic log headers.
  private var appVersionString: String {
    let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    return "\(v) (\(b))"
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
    windowLayoutCoordinator?.stop()
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

    // Edit menu — required for standard text field shortcuts (Cmd+A/C/X/V/Z)
    let editMenuItem = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(
      withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editMenuItem.submenu = editMenu
    mainMenu.addItem(editMenuItem)

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
    Diagnostics.log("panel", "switcher show")
    viewModel.overrideDisplayUUID = nil
    viewModel.displayArrangement = Self.currentArrangement()
    viewModel.showEmptySpaces = appSettings.showEmptySpaces
    viewModel.warpCursorOnActivation = appSettings.warpCursorOnActivation
    viewModel.activateMovedItem = appSettings.activateMovedItem

    let multiPanel = isMultiPanelPerDisplay
    let screens = targetScreens()
    let activeScreen = NSScreen.main ?? NSScreen.screens.first!
    let activeUUID = Self.displayUUID(for: activeScreen)

    // Mode 3: no ViewModel-level filter; each view filters its own display.
    // Mode 2: ViewModel filters to the focused display.
    // Mode 1: no filter.
    viewModel.filterByDisplay = appSettings.filterSpacesByDisplay && !multiPanel
    viewModel.spaceSortOrder = appSettings.spaceSortOrder

    if !multiPanel {
      viewModel.displayOrder = []
    }

    // Refresh before building the display order: the MRU-top display is a
    // refresh product.
    viewModel.refresh()

    if multiPanel {
      // Build display order: the display of the most recently used space
      // first, then the rest in screen order. Keyed off the view model's MRU
      // rather than NSScreen.main because keyboard focus can lag or never
      // follow an activation (empty spaces, freshly moved spaces) — the
      // initial selection lands in the first display group, and it should
      // start on the space the user most recently activated.
      var order: [String] = []
      if let uuid = viewModel.mruTopDisplayUUID ?? activeUUID { order.append(uuid) }
      for screen in NSScreen.screens {
        if let uuid = Self.displayUUID(for: screen), !order.contains(uuid) {
          order.append(uuid)
        }
      }
      viewModel.displayOrder = order

      // The Workspaces/Settings rows live on the built-in display's panel only
      // (falling back to the first screen when the lid is closed).
      let screenUUIDs = NSScreen.screens.compactMap { Self.displayUUID(for: $0) }
      let builtin = SpaceManager.builtinDisplayUUID()
      viewModel.metaRowsDisplayUUID =
        builtin.flatMap { screenUUIDs.contains($0) ? $0 : nil } ?? screenUUIDs.first
    } else {
      viewModel.metaRowsDisplayUUID = nil
    }

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
    keyInterceptor.setSuppressConfirm(false)
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
    Diagnostics.log("panel", "switcher hide")
    if viewModel.panelMode == .createSpace {
      viewModel.exitCreateMode()
    }
    if viewModel.moveMode {
      viewModel.cancelMoveMode()
    }
    if viewModel.spaceMoveMode {
      viewModel.cancelSpaceMoveMode()
    }
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

  /// Names each external display's sole unnamed desktop space "Default
  /// Space" — a pinned anchor space, so any named space on that display can
  /// always be moved away without first creating a sibling. Idempotent;
  /// runs at launch and on every display reconfiguration.
  private func assignDefaultSpaceNames() {
    DefaultSpaceNamer.assignNames(
      spaces: viewModel.spaceManager.getAllSpaces(),
      builtinDisplayUUID: SpaceManager.builtinDisplayUUID(),
      store: spaceNameStore)
  }

  /// The physical layout of the connected displays, in NSScreen (y-up)
  /// global coordinates.
  private static func currentArrangement() -> DisplayArrangement {
    DisplayArrangement(
      displays: NSScreen.screens.compactMap { screen in
        displayUUID(for: screen).map {
          DisplayArrangement.Display(uuid: $0, frame: screen.frame)
        }
      })
  }

  /// Moves the selection to the display physically in `direction`, wrapping
  /// past the far edge; no-op when no display lies on that axis.
  private func navigateDisplay(_ direction: ArrangementDirection) {
    // Never touch panel content while a move is pending — refresh() would wipe
    // the visual relocation and the marked item's context (issue #18). The
    // delegate method routes these keys to the marked-item movers instead;
    // this guard is belt-and-braces for any other caller.
    guard !viewModel.moveMode && !viewModel.spaceMoveMode else { return }
    guard appSettings.filterSpacesByDisplay else { return }
    guard NSScreen.screens.count > 1 else { return }

    let currentUUID =
      isMultiPanelPerDisplay
      ? (viewModel.activeDisplayUUID ?? viewModel.displayOrder.first)
      : currentPanelDisplayUUID
    guard let currentUUID,
      let targetUUID = Self.currentArrangement().wrappedNeighborUUID(
        of: currentUUID, direction: direction)
    else { return }
    focusDisplay(uuid: targetUUID)
  }

  private func focusDisplay(uuid targetUUID: String) {
    if isMultiPanelPerDisplay {
      // Mode 3: move selection to the target display's first window
      // and make that panel the key window.
      viewModel.selectFirstWindow(onDisplay: targetUUID)
      if let targetPanel = panels.first(where: { $0.displayUUID == targetUUID }) {
        targetPanel.makeKeyAndOrderFront(nil)
      }
      currentPanelDisplayUUID = targetUUID
    } else {
      // Mode 2: single panel, switch its display content
      guard
        let targetScreen = NSScreen.screens.first(where: {
          Self.displayUUID(for: $0) == targetUUID
        })
      else { return }
      viewModel.overrideDisplayUUID = targetUUID
      viewModel.refresh()
      viewModel.resetSelection()

      let panel = panels[0]
      _ = resizePanelToFit(panel, on: targetScreen)
      centerPanel(panel, on: targetScreen)
      currentPanelDisplayUUID = targetUUID
    }
  }

  /// Mode 3: makes the panel rendering `item` the key window, so keyboard
  /// focus follows the selection across displays. No-op in single-panel modes
  /// and while the panels are hidden (their displayUUIDs are nil then).
  private func syncKeyPanel(toSelection item: SelectedItem?) {
    guard isMultiPanelPerDisplay,
      let uuid = viewModel.panelDisplayUUID(for: item),
      let panel = panels.first(where: { $0.displayUUID == uuid }),
      panel.isVisible, !panel.isKeyWindow
    else { return }
    panel.makeKeyAndOrderFront(nil)
    currentPanelDisplayUUID = uuid
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

  private func resizePanelsToFit() {
    // Defer to next run loop so SwiftUI layout settles first
    DispatchQueue.main.async { [self] in
      let screens = targetScreens()
      for (i, screen) in screens.enumerated() where i < panels.count {
        _ = resizePanelToFit(panels[i], on: screen)
        centerPanel(panels[i], on: screen)
      }
    }
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

  // MARK: - Resize Panel Management

  private func showResizePanel() {
    Diagnostics.log("panel", "resize show")
    // Dismiss switcher panel if open
    if keyInterceptor.panelVisible {
      hidePanel()
    }

    resizeViewModel.captureCurrentWindow()

    resizeViewModel.onResizeComplete = { [weak self] in
      self?.hideResizePanel()
    }

    let allScreens = NSScreen.screens
    let activeScreen = resizeViewModel.targetScreen ?? NSScreen.main ?? allScreens.first!
    let activeUUID = Self.displayUUID(for: activeScreen)

    // Ensure enough resize panels
    while resizePanels.count < allScreens.count {
      resizePanels.append(ResizePanel(contentRect: .zero))
    }

    // Show a resize panel on each screen
    for (i, screen) in allScreens.enumerated() {
      let panel = resizePanels[i]
      let screenUUID = Self.displayUUID(for: screen)
      let rootView = ResizeView(
        viewModel: resizeViewModel, settings: appSettings, displayUUID: screenUUID)
      panel.setRootView(rootView)
      applyResizePanelAppearance(panel)

      // Size and center on this screen
      panel.contentView?.layoutSubtreeIfNeeded()
      if let hostingView = panel.contentView {
        panel.setContentSize(hostingView.fittingSize)
      }
      let panelSize = panel.frame.size
      let screenFrame = screen.visibleFrame
      let x = screenFrame.midX - panelSize.width / 2
      let y = screenFrame.midY - panelSize.height / 2 + screenFrame.height * 0.05
      panel.setFrameOrigin(NSPoint(x: x, y: y))

      if Self.displayUUID(for: screen) == activeUUID {
        panel.makeKeyAndOrderFront(nil)
      } else {
        panel.orderFront(nil)
      }
    }

    // Hide extra panels from a previous show with more screens
    for i in allScreens.count..<resizePanels.count {
      resizePanels[i].orderOut(nil)
    }

    // Show the full-screen grid overlay on all displays
    resizeViewModel.previewGridColumns = appSettings.resizeGridColumns
    resizeViewModel.previewGridRows = appSettings.resizeGridRows
    while resizeOverlays.count < allScreens.count {
      resizeOverlays.append(ResizeOverlay())
    }
    for (i, screen) in allScreens.enumerated() {
      resizeOverlays[i].show(
        on: screen, viewModel: resizeViewModel, settings: appSettings,
        displayUUID: Self.displayUUID(for: screen))
    }
    for i in allScreens.count..<resizeOverlays.count {
      resizeOverlays[i].dismiss()
    }

    keyInterceptor.setResizePanelVisible(true)
  }

  private func hideResizePanel() {
    Diagnostics.log("panel", "resize hide")
    for panel in resizePanels {
      panel.orderOut(nil)
    }
    for overlay in resizeOverlays {
      overlay.dismiss()
    }
    resizeViewModel.previewRegion = nil
    keyInterceptor.setResizePanelVisible(false)
  }

  private func applyResizePanelAppearance(_ panel: ResizePanel) {
    switch appSettings.colorScheme {
    case .auto:
      panel.appearance = nil
    case .light:
      panel.appearance = NSAppearance(named: .aqua)
    case .dark:
      panel.appearance = NSAppearance(named: .darkAqua)
    }
  }
}

// MARK: - KeyInterceptorDelegate

extension AppDelegate: KeyInterceptorDelegate {
  func keyInterceptorReady() {
    // The tap just came up (Accessibility granted) — re-check the rest.
    permissionsCoordinator?.checkAndPrompt()
  }

  func keyInterceptorShowPanel() {
    showPanel()
  }

  func keyInterceptorAdvanceAfterOpen() {
    // The Cmd+Tab that opened the panel: advance to the second row unless
    // the active window sits alone on its display's only space.
    guard !viewModel.shouldKeepInitialSelectionOnOpen else { return }
    keyInterceptorMoveDown()
  }

  func keyInterceptorMoveDown() {
    if viewModel.panelMode == .createSpace {
      viewModel.moveCreateSelectionDown()
    } else if viewModel.moveMode {
      viewModel.moveMarkedWindowToNextSpace()
      resizePanelsToFit()
    } else if viewModel.spaceMoveMode {
      viewModel.moveMarkedSpaceToNextDisplay()
      resizePanelsToFit()
    } else {
      viewModel.moveSelectionDown()
    }
  }

  func keyInterceptorMoveUp() {
    if viewModel.panelMode == .createSpace {
      viewModel.moveCreateSelectionUp()
    } else if viewModel.moveMode {
      viewModel.moveMarkedWindowToPreviousSpace()
      resizePanelsToFit()
    } else if viewModel.spaceMoveMode {
      viewModel.moveMarkedSpaceToPreviousDisplay()
      resizePanelsToFit()
    } else {
      viewModel.moveSelectionUp()
    }
  }

  func keyInterceptorConfirm() {
    if viewModel.panelMode == .createSpace {
      confirmCreateMenuSelection()
      return
    }
    // Move mode: execute the move instead of normal activation. The panel is
    // dismissed either way — a no-op move (item back on its origin) should
    // end the interaction like any other confirm, not leave the panel
    // stranded with the mode silently cancelled (issue #18).
    if viewModel.moveMode {
      _ = viewModel.executeMoveWindow()
      hidePanel()
      return
    }
    if viewModel.spaceMoveMode {
      _ = viewModel.executeMoveSpace()
      hidePanel()
      return
    }
    switch viewModel.selectedItem {
    case .spaces:
      viewModel.enterCreateMode(
        workspaces: appSettings.workspaces, displayUUID: viewModel.contextDisplayUUID)
      resizePanelsToFit()
    case .settings:
      openSettings()
    case .eject:
      keyInterceptorEjectSpaces()
    case .spaceHeader, .windowRow:
      activateAndDismiss()
    case nil:
      break
    }
  }

  func keyInterceptorCancel() {
    if viewModel.panelMode == .createSpace {
      viewModel.exitCreateMode()
      resizePanelsToFit()
      return
    }
    if viewModel.moveMode {
      viewModel.cancelMoveMode()
      return
    }
    if viewModel.spaceMoveMode {
      viewModel.cancelSpaceMoveMode()
      viewModel.refresh()
      return
    }
    hidePanel()
  }

  func keyInterceptorCloseWindow() {
    viewModel.closeSelectedWindow()
  }

  func keyInterceptorQuitApp() {
    viewModel.quitSelectedApp()
  }

  func keyInterceptorMinimizeWindow() {
    viewModel.minimizeSelectedWindow()
  }

  func keyInterceptorMinimizeSpace() {
    viewModel.minimizeSelectedSpace()
  }

  func keyInterceptorOpenSettings() {
    openSettings()
  }

  func keyInterceptorMoveDisplay(_ direction: ArrangementDirection) {
    if viewModel.moveMode {
      viewModel.moveMarkedWindow(inDirection: direction)
      resizePanelsToFit()
    } else if viewModel.spaceMoveMode {
      viewModel.moveMarkedSpace(inDirection: direction)
      resizePanelsToFit()
    } else {
      navigateDisplay(direction)
    }
  }

  func keyInterceptorJumpToNextSpace() {
    if viewModel.panelMode == .createSpace {
      viewModel.moveCreateSelectionDown()
    } else if viewModel.moveMode {
      viewModel.moveMarkedWindowToNextSpace()
      resizePanelsToFit()
    } else if viewModel.spaceMoveMode {
      // A marked space only moves display-to-display, so ↓ is directional
      // like the rest; Cmd+Tab keeps the linear cycle for reachability.
      viewModel.moveMarkedSpace(inDirection: .down)
      resizePanelsToFit()
    } else {
      viewModel.moveToNextSpace()
    }
  }

  func keyInterceptorJumpToPreviousSpace() {
    if viewModel.panelMode == .createSpace {
      viewModel.moveCreateSelectionUp()
    } else if viewModel.moveMode {
      viewModel.moveMarkedWindowToPreviousSpace()
      resizePanelsToFit()
    } else if viewModel.spaceMoveMode {
      viewModel.moveMarkedSpace(inDirection: .up)
      resizePanelsToFit()
    } else {
      viewModel.moveToPreviousSpace()
    }
  }

  func keyInterceptorStartRename() {
    guard viewModel.canRenameFromCurrentSelection else { return }
    viewModel.startRenaming()
    guard viewModel.isRenaming else { return }
    keyInterceptor.setRenameMode(true)
  }

  func keyInterceptorToggleMoveMode() {
    viewModel.toggleMoveMode()
  }

  func keyInterceptorRestoreSpaces() {
    guard !spaceEvacuationInFlight else { return }
    keyInterceptor.setSuppressConfirm(true)
    hidePanel()
    runSpaceRestore(onlyArmed: false, showOverlay: true)
  }

  func keyInterceptorEjectSpaces() {
    guard !spaceEvacuationInFlight else { return }
    keyInterceptor.setSuppressConfirm(true)
    hidePanel()

    spaceEvacuationInFlight = true
    let planned = EjectPlanner.plan(
      spaces: viewModel.spaceManager.getAllSpaces(),
      targetDisplayUUID: SpaceManager.builtinDisplayUUID() ?? "",
      names: spaceNameStore.allCustomNames())
    spaceTransferShield.begin(operation: .eject, plannedMoves: planned.moves.count)

    DispatchQueue.global(qos: .userInteractive).async { [weak self] in
      guard let self else { return }
      let result = Result {
        try self.viewModel.spaceManager.ejectSpaces(
          spaceNameStore: self.spaceNameStore, ejectStore: self.ejectStore)
      }
      DispatchQueue.main.async {
        self.spaceEvacuationInFlight = false
        let message: String
        switch result {
        case .success(let summary):
          if summary.ejected.isEmpty && summary.failed.isEmpty {
            message = "Nothing to eject"
          } else {
            let count = summary.ejected.count
            var resultMessage = "Ejected \(count) Space\(count == 1 ? "" : "s")"
            if !summary.failed.isEmpty {
              resultMessage += " (\(summary.failed.count) failed)"
            }
            message = resultMessage
          }
        case .failure(let error):
          message = "Eject failed: \(error.localizedDescription)"
        }
        self.spaceTransferShield.finish(message: message)
      }
    }
  }

  /// Arms the origin displays that are currently absent. Auto-restore only
  /// touches origins on ARMED displays — a display must actually go away
  /// after the eject before its spaces auto-return, so spurious display
  /// events (sleep/wake, resolution changes) can't undo an eject whose
  /// displays never left. Runs at launch (records persist across restarts)
  /// and on every display reconfiguration.
  private func armEjectionRecords() {
    let pending = ejectStore.pendingEjections()
    guard !pending.isEmpty else { return }
    let connected = Set(viewModel.spaceManager.getAllSpaces().map(\.displayUUID))
    let absent = Set(pending.values.flatMap { $0 }).subtracting(connected)
    ejectStore.armDisplays(absent.sorted())
  }

  /// Debounced auto-restore: display reconfiguration fires several times per
  /// reconnect and CGS needs a beat to settle, so restoration runs once,
  /// 2 seconds after the last event — and only for ARMED records whose
  /// display is actually back.
  private func scheduleEjectionRestore() {
    // A real display event starts a fresh retry budget; retries themselves
    // reschedule via scheduleRestoreCheck without touching the counter.
    restoreFailedAttempts = 0
    scheduleRestoreCheck(after: 2.0)
  }

  private func scheduleRestoreCheck(after delay: TimeInterval) {
    pendingRestoreWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.restoreEjectedSpacesIfReady() }
    pendingRestoreWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private func restoreEjectedSpacesIfReady() {
    // An eject or restore is mid-flight — defer rather than drop, or a
    // reconfiguration landing during a ~12s restore run would be swallowed
    // and its Spaces left stranded until the next reconnect. (A post-eject
    // deferral is harmless: freshly ejected records aren't armed yet, so the
    // deferred check no-ops.)
    if spaceEvacuationInFlight {
      Diagnostics.log("eject", "restore check deferred — evacuation in flight")
      scheduleRestoreCheck(after: 2.0)
      return
    }
    let plan = viewModel.spaceManager.restorePlan(ejectStore: ejectStore, onlyArmed: true)
    // Stale/already-home records still need clearing even when nothing
    // moves, but only a real move warrants the overlay and input blocking.
    let hasMoves = !plan.moves.isEmpty
    if !hasMoves && plan.stale.isEmpty && plan.completed.isEmpty { return }

    runSpaceRestore(onlyArmed: true, showOverlay: hasMoves)
  }

  /// After an automatic restore run, retries with backoff when armed records
  /// that could move remain — a run right after reconnect can fail wholesale
  /// while Mission Control's AX hierarchy is still rebuilding, and without a
  /// retry those Spaces sit unrestored until the next display event.
  private func scheduleRetryIfIncomplete() {
    let plan = viewModel.spaceManager.restorePlan(ejectStore: ejectStore, onlyArmed: true)
    guard !plan.moves.isEmpty else {
      // Only waiting-for-display records remain — a retry can't help them.
      restoreFailedAttempts = 0
      return
    }
    restoreFailedAttempts += 1
    guard let delay = restoreRetryPolicy.retryDelay(afterFailedAttempts: restoreFailedAttempts)
    else {
      Diagnostics.log(
        "eject",
        "auto-restore gave up after \(restoreFailedAttempts) attempts — "
          + "\(plan.moves.count) move(s) still pending until the next display event")
      return
    }
    Diagnostics.log(
      "eject",
      "auto-restore incomplete (\(plan.moves.count) move(s) remain) — "
        + "retry #\(restoreFailedAttempts) in \(delay)s")
    scheduleRestoreCheck(after: delay)
  }

  /// Shared restore runner for the auto path (armed records only) and the
  /// manual Cmd+Shift+E path (everything movable).
  private func runSpaceRestore(onlyArmed: Bool, showOverlay: Bool) {
    let plan = viewModel.spaceManager.restorePlan(ejectStore: ejectStore, onlyArmed: onlyArmed)
    let hadPending = !plan.isEmpty
    spaceEvacuationInFlight = true
    if showOverlay {
      spaceTransferShield.begin(operation: .restore, plannedMoves: plan.moves.count)
    }

    DispatchQueue.global(qos: .userInteractive).async { [weak self] in
      guard let self else { return }
      let result = Result {
        try self.viewModel.spaceManager.restoreEjectedSpaces(
          ejectStore: self.ejectStore, onlyArmed: onlyArmed)
      }
      DispatchQueue.main.async {
        self.spaceEvacuationInFlight = false
        if onlyArmed { self.scheduleRetryIfIncomplete() }
        guard showOverlay else { return }
        let message: String
        switch result {
        case .success(let summary) where !summary.restored.isEmpty:
          let count = summary.restored.count
          var resultMessage = "Restored \(count) Space\(count == 1 ? "" : "s")"
          if !summary.waiting.isEmpty {
            resultMessage += " (\(summary.waiting.count) awaiting a display)"
          }
          message = resultMessage
        case .success(let summary) where !summary.waiting.isEmpty:
          message = "\(summary.waiting.count) Space(s) awaiting a disconnected display"
        case .success:
          message =
            hadPending
            ? "Space restore incomplete — will retry on reconnect"
            : "Nothing to restore"
        case .failure(let error):
          message = "Restore failed: \(error.localizedDescription)"
        }
        self.spaceTransferShield.finish(message: message)
      }
    }
  }

  func keyInterceptorToggleSpaceMoveMode() {
    viewModel.toggleSpaceMoveMode()
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

  func keyInterceptorCloseSpace() {
    guard let spaceID = viewModel.selectedSpaceID else { return }

    // Don't close the last space
    let desktopCount = viewModel.spaceManager.getAllSpaces().filter({ $0.type == .desktop }).count
    guard desktopCount > 1 else {
      viewModel.sortOverlayText = "Cannot close the last space"
      viewModel.sortOverlayGeneration += 1
      return
    }

    let spaceName =
      viewModel.filteredSections.first(where: { $0.id == spaceID })?.label ?? "Space \(spaceID)"

    // Capture the next MRU space before closing (sections are MRU-ordered)
    let nextMRUSpaceID = viewModel.sections
      .first(where: { $0.id != spaceID })?.id

    keyInterceptor.setSuppressConfirm(true)
    viewModel.sortOverlayText = "Closing \(spaceName)..."
    viewModel.sortOverlayGeneration += 1

    // Hide panel before the close so MC can open cleanly
    hidePanel()

    viewModel.spaceManager.closeSpaceWithWindowsAndRemoveName(
      id: spaceID, spaceNameStore: viewModel.spaceNameStore
    ) { [weak self] result in
      guard let self else { return }

      // Switch to the next MRU space after successful close
      if case .success = result, let nextID = nextMRUSpaceID {
        try? self.viewModel.spaceManager.switchToSpace(id: nextID)
      }

      DispatchQueue.main.async {
        if case .failure(let error) = result {
          self.viewModel.sortOverlayText = error.localizedDescription
          self.viewModel.sortOverlayGeneration += 1
          self.showPanel()
        }
      }
    }
  }

  func keyInterceptorToggleCreateMenu() {
    if viewModel.panelMode == .createSpace {
      viewModel.exitCreateMode()
      resizePanelsToFit()
    } else {
      viewModel.enterCreateMode(
        workspaces: appSettings.workspaces, displayUUID: viewModel.contextDisplayUUID)
      resizePanelsToFit()
    }
  }

  private func confirmCreateMenuSelection() {
    guard !spaceEvacuationInFlight else { return }
    guard let selIdx = viewModel.createMenuSelection,
      selIdx < viewModel.createMenuItems.count
    else { return }

    let item = viewModel.createMenuItems[selIdx]

    // "Back" — just exit create mode, return to normal panel
    if item.workspaceIndex == SwitcherViewModel.backWorkspaceIndex {
      viewModel.exitCreateMode()
      resizePanelsToFit()
      return
    }

    // Use the display captured when entering create mode
    let activeScreenNumber: CGDirectDisplayID? = {
      if let uuid = viewModel.createModeDisplayUUID {
        return SpaceManager.displayIDForUUID(uuid)
      }
      return nil
    }()

    viewModel.exitCreateMode()
    hidePanel()

    if let wsIdx = item.workspaceIndex {
      // Determine which workspaces to restore
      let workspacesToRestore: [WorkspaceConfig]
      if wsIdx == SwitcherViewModel.allSpacesWorkspaceIndex {
        workspacesToRestore = appSettings.workspaces
      } else {
        workspacesToRestore = [appSettings.workspaces[wsIdx]]
      }
      keyInterceptor.setSuppressConfirm(true)
      spaceEvacuationInFlight = true

      let displayName =
        workspacesToRestore.count == 1
        ? workspacesToRestore[0].name : "workspaces"
      spaceTransferShield.begin(
        operation: .workspaceRestore(name: displayName),
        plannedMoves: workspacesToRestore.reduce(0) { $0 + $1.launchers.count })

      // Safety timeout — window placement may include a Mission Control move.
      let restoreTimeout = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.spaceTransferShield.finish(message: "Setup timed out")
        // Release input, but keep the shared automation gate until the worker
        // actually returns: a timeout cannot cancel an in-flight launcher.
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: restoreTimeout)

      DispatchQueue.global(qos: .userInteractive).async { [weak self] in
        guard let self else { return }

        let restorer = WorkspaceRestorer(
          spaceManager: self.viewModel.spaceManager,
          spaceNameStore: self.viewModel.spaceNameStore,
          windowLayoutRestorer: WorkspaceWindowLayoutRestorer(store: self.windowLayoutStore)
        )

        let data = workspacesToRestore.map { ws in
          WorkspaceConfigData(
            id: ws.id.uuidString,
            name: ws.name,
            path: ws.path,
            launchers: ws.launchers.map { l in
              LauncherData(
                label: l.label,
                steps: l.steps,
                appName: l.appName,
                bundleID: l.bundleID,
                allowsExistingWindow: l.allowsExistingWindow)
            }
          )
        }

        let summary = try? restorer.restoreSync(
          workspaces: data,
          defaultNames: workspacesToRestore.map(\.name)
        )

        DispatchQueue.main.async {
          restoreTimeout.cancel()
          self.spaceEvacuationInFlight = false
          let message: String
          if let summary {
            message =
              summary.errors.isEmpty
              ? "Restored \(displayName)"
              : "Restored \(displayName) with \(summary.errors.count) error(s)"
          } else {
            message = "Failed to set up \(displayName)"
          }
          self.spaceTransferShield.finish(message: message)
        }
      }
    } else {
      // "New Space" — create unnamed space on the active display
      keyInterceptor.setSuppressConfirm(true)

      viewModel.spaceManager.createSpace(
        count: 1, screenNumber: activeScreenNumber, switchToNewSpace: true
      ) {
        [weak self] result in
        guard let self else { return }

        // Switch to the newly created space (the last desktop on the display)
        if case .success = result {
          let allSpaces = self.viewModel.spaceManager.getAllSpaces()
          let displayUUID: String? = {
            if let sn = activeScreenNumber {
              return allSpaces.first(where: {
                SpaceManager.displayIDForUUID($0.displayUUID) == sn
              })?.displayUUID
            }
            return allSpaces.first?.displayUUID
          }()
          if let uuid = displayUUID {
            let desktops = allSpaces.filter {
              $0.displayUUID == uuid && $0.type == .desktop
            }
            if let lastSpace = desktops.last {
              // Through the view model so the new space earns its MRU stamp —
              // focus inference can't see a switch to a windowless space, and
              // the panel would list the fresh space buried mid-list.
              DispatchQueue.main.async {
                self.viewModel.activateSpace(id: lastSpace.id)
              }
            }
          }
        }

        DispatchQueue.main.async {
          if case .failure(let error) = result {
            self.viewModel.sortOverlayText = error.localizedDescription
            self.viewModel.sortOverlayGeneration += 1
            self.showPanel()
          }
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

  func keyInterceptorShowResize() {
    showResizePanel()
  }

  func keyInterceptorResizeCommit() {
    // Defer hideResizePanel until the async resize chain finishes — otherwise the panel-hide
    // returns focus to the target app mid-resize, and apps with animated resizes (iTerm,
    // IntelliJ) cancel the in-progress animation when their window becomes key again.
    resizeViewModel.commitResize(margins: CGFloat(appSettings.resizeMargins)) {
      [weak self] in
      self?.hideResizePanel()
    }
  }

  func keyInterceptorResizeCancel() {
    hideResizePanel()
  }

  func keyInterceptorResizePreset(keyCode: UInt16) {
    guard let preset = appSettings.resizePresets.first(where: { $0.keyCode == keyCode }) else {
      return
    }
    resizeViewModel.applyPreset(preset, margins: CGFloat(appSettings.resizeMargins))
    keyInterceptor.setResizePresetApplied()
  }
}
