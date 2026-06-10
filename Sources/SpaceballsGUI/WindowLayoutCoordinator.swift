import Cocoa
import SpaceballsCore
import SpaceballsGUILib

/// Subscribes to space-change, display-reconfig, and Spaceballs-resize events
/// and orchestrates capture + lazy restore via `WindowLayoutStore`.
final class WindowLayoutCoordinator {
  private let store: WindowLayoutStore
  private let spaceManager: SpaceManager
  private let appSettings: AppSettings
  private var observers: [NSObjectProtocol] = []

  init(store: WindowLayoutStore, spaceManager: SpaceManager, appSettings: AppSettings) {
    self.store = store
    self.spaceManager = spaceManager
    self.appSettings = appSettings
  }

  func start() {
    seedLastSeenDisplays()

    let workspaceCenter = NSWorkspace.shared.notificationCenter
    observers.append(
      workspaceCenter.addObserver(
        forName: NSWorkspace.activeSpaceDidChangeNotification,
        object: nil, queue: .main
      ) { [weak self] _ in
        self?.handleSpaceOrDisplayChange()
      })

    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification,
        object: nil, queue: .main
      ) { [weak self] _ in
        // CGS display assignments lag the screen-parameters notification on
        // some macOS versions; wait briefly before reading.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
          self?.handleSpaceOrDisplayChange()
        }
      })

    observers.append(
      NotificationCenter.default.addObserver(
        forName: WindowResizer.didResizeWindowNotification,
        object: nil, queue: .main
      ) { [weak self] note in
        self?.handleResize(note)
      })
  }

  func stop() {
    let workspaceCenter = NSWorkspace.shared.notificationCenter
    let defaultCenter = NotificationCenter.default
    for token in observers {
      workspaceCenter.removeObserver(token)
      defaultCenter.removeObserver(token)
    }
    observers.removeAll()
  }

  // MARK: - Event Handlers

  private func handleSpaceOrDisplayChange() {
    guard appSettings.rememberWindowLayouts else { return }

    let spaces = spaceManager.getAllSpaces()
    // For every display's currently-active space, restore if the display
    // differs from the last one we saw it on.
    let activeSpaces = spaces.filter { $0.isCurrent }

    for space in activeSpaces {
      let last = store.lastSeenDisplayUUID(forSpace: space.uuid)
      if last != space.displayUUID {
        store.restore(spaceUUID: space.uuid, displayUUID: space.displayUUID)
        store.setLastSeenDisplay(spaceUUID: space.uuid, displayUUID: space.displayUUID)
      }
    }
  }

  private func handleResize(_ note: Notification) {
    guard appSettings.rememberWindowLayouts else { return }
    guard let userInfo = note.userInfo,
      let pid = userInfo["pid"] as? pid_t,
      let bundleID = userInfo["bundleID"] as? String,
      !bundleID.isEmpty
    else { return }

    // Give the window a moment to settle into its new frame before reading.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      self?.store.captureWindow(pid: pid, bundleID: bundleID)
    }
  }

  /// Records the current display for every active Space at startup so we don't
  /// mistake a normal first-visit for a display reconfig.
  private func seedLastSeenDisplays() {
    let spaces = spaceManager.getAllSpaces()
    for space in spaces where space.isCurrent {
      if store.lastSeenDisplayUUID(forSpace: space.uuid) == nil {
        store.setLastSeenDisplay(spaceUUID: space.uuid, displayUUID: space.displayUUID)
      }
    }
  }
}
