import Cocoa
import SpacebarGUILib

protocol KeyInterceptorDelegate: AnyObject {
  func keyInterceptorShowPanel()
  func keyInterceptorMoveDown()
  func keyInterceptorMoveUp()
  func keyInterceptorConfirm()
  func keyInterceptorCancel()
  func keyInterceptorReady()
  func keyInterceptorOpenSettings()
  func keyInterceptorCloseWindow()
  func keyInterceptorQuitApp()
  func keyInterceptorCycleDisplayLeft()
  func keyInterceptorCycleDisplayRight()
  func keyInterceptorJumpToNextSpace()
  func keyInterceptorJumpToPreviousSpace()
  func keyInterceptorStartRename()
  func keyInterceptorCommitRename()
  func keyInterceptorCancelRename()
  func keyInterceptorCycleSortOrder()
  func keyInterceptorCreateDefaultSpaces()
  func keyInterceptorCloseSpace()
}

/// Global reference for signal handler cleanup. The event tap MUST be removed
/// before the process exits, otherwise macOS will queue all HID events behind
/// the dead tap, freezing keyboard/mouse input system-wide.
private var activeEventTap: CFMachPort?

private func signalHandler(_ signal: Int32) {
  if let tap = activeEventTap {
    CGEvent.tapEnable(tap: tap, enable: false)
    activeEventTap = nil
  }
  // Re-raise with default handler so the process actually terminates
  Darwin.signal(signal, SIG_DFL)
  Darwin.raise(signal)
}

final class KeyInterceptor {
  weak var delegate: KeyInterceptorDelegate?
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private(set) var panelVisible = false
  private(set) var renameMode = false
  private(set) var recordingMode = false
  var suppressConfirm = false
  var keyBindings = KeyBindings()

  func setPanelVisible(_ visible: Bool) {
    panelVisible = visible
  }

  func setRenameMode(_ active: Bool) {
    renameMode = active
  }

  func setSuppressConfirm(_ suppress: Bool) {
    suppressConfirm = suppress
  }

  func setRecordingMode(_ active: Bool) {
    recordingMode = active
  }

  private var pollTimer: Timer?

  func start() {
    if AXIsProcessTrusted() {
      createEventTap()
    } else {
      // Prompt the user to grant Accessibility permission
      let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
      AXIsProcessTrustedWithOptions(options)
      print(
        "Waiting for Accessibility permission... Grant access in System Settings → Privacy & Security → Accessibility."
      )

      // Poll until permission is granted, then create the tap
      pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
        [weak self] timer in
        if AXIsProcessTrusted() {
          timer.invalidate()
          self?.pollTimer = nil
          print("Accessibility permission granted.")
          self?.createEventTap()
        }
      }
    }
  }

  private func installSignalHandlers() {
    activeEventTap = eventTap
    Darwin.signal(SIGTERM, signalHandler)
    Darwin.signal(SIGINT, signalHandler)
    Darwin.signal(SIGHUP, signalHandler)
  }

  private func createEventTap() {
    let eventMask: CGEventMask =
      (1 << CGEventType.keyDown.rawValue)
      | (1 << CGEventType.keyUp.rawValue)
      | (1 << CGEventType.flagsChanged.rawValue)

    // The callback must be a C function pointer — no captures allowed.
    // We pass `self` via userInfo.
    guard
      let tap = CGEvent.tapCreate(
        tap: .cghidEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: eventMask,
        callback: keyInterceptorCallback,
        userInfo: Unmanaged.passUnretained(self).toOpaque()
      )
    else {
      print("ERROR: Failed to create CGEvent tap even though AXIsProcessTrusted() is true.")
      print(
        "Try removing and re-adding Spacebar in System Settings → Privacy & Security → Accessibility."
      )
      return
    }

    eventTap = tap

    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    runLoopSource = source
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    installSignalHandlers()
    print("Event tap active — Cmd+Tab interception enabled.")
    delegate?.keyInterceptorReady()
  }

  func stop() {
    pollTimer?.invalidate()
    pollTimer = nil
    if let tap = eventTap {
      CGEvent.tapEnable(tap: tap, enable: false)
    }
    if let source = runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
    }
    activeEventTap = nil
    eventTap = nil
    runLoopSource = nil
  }

  /// Re-enable the tap if macOS disabled it (happens if callback is too slow).
  func ensureEnabled() {
    if let tap = eventTap, !CGEvent.tapIsEnabled(tap: tap) {
      CGEvent.tapEnable(tap: tap, enable: true)
    }
  }
}

// MARK: - C callback

private func keyInterceptorCallback(
  proxy: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let userInfo else { return Unmanaged.passUnretained(event) }
  let interceptor = Unmanaged<KeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()

  // If the tap was disabled by the system, re-enable it
  if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
    interceptor.ensureEnabled()
    return Unmanaged.passUnretained(event)
  }

  // Recording mode — pass through all events so the key recorder can capture them
  if interceptor.recordingMode {
    return Unmanaged.passUnretained(event)
  }

  let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
  let flags = event.flags
  let bindings = interceptor.keyBindings

  switch type {
  case .keyDown:
    let cmdHeld = flags.contains(.maskCommand)

    // Rename mode — most keys pass through to the TextField
    if interceptor.renameMode {
      // Enter/Return (36/76) — commit rename
      if keyCode == 36 || keyCode == 76 {
        DispatchQueue.main.async {
          interceptor.delegate?.keyInterceptorCommitRename()
        }
        return nil  // consume
      }
      // Escape (53) — cancel rename
      if keyCode == 53 {
        DispatchQueue.main.async {
          interceptor.delegate?.keyInterceptorCancelRename()
        }
        return nil  // consume
      }
      // Activate key — commit rename, then move down
      if cmdHeld && keyCode == Int64(bindings.activateAndNext) {
        DispatchQueue.main.async {
          interceptor.delegate?.keyInterceptorCommitRename()
          interceptor.delegate?.keyInterceptorMoveDown()
        }
        return nil  // consume
      }
      // Previous item key — commit rename, then move up
      if cmdHeld && keyCode == Int64(bindings.previousItem) {
        DispatchQueue.main.async {
          interceptor.delegate?.keyInterceptorCommitRename()
          interceptor.delegate?.keyInterceptorMoveUp()
        }
        return nil  // consume
      }
      // Close / Quit / next-space / prev-space — no-op during rename
      if cmdHeld
        && (keyCode == Int64(bindings.closeWindow) || keyCode == Int64(bindings.quitApp)
          || keyCode == Int64(bindings.nextSpace)
          || keyCode == Int64(bindings.previousSpace))
      {
        return nil  // consume
      }
      // Everything else — pass through to TextField
      return Unmanaged.passUnretained(event)
    }

    // Activate / Next item
    if cmdHeld && keyCode == Int64(bindings.activateAndNext) {
      DispatchQueue.main.async {
        if !interceptor.panelVisible {
          interceptor.delegate?.keyInterceptorShowPanel()
        }
        interceptor.delegate?.keyInterceptorMoveDown()
      }
      return nil  // consume
    }

    // Previous item
    if cmdHeld && keyCode == Int64(bindings.previousItem) {
      DispatchQueue.main.async {
        if interceptor.panelVisible {
          interceptor.delegate?.keyInterceptorMoveUp()
        }
      }
      return nil  // consume
    }

    // Next space (Cmd held)
    if cmdHeld && keyCode == Int64(bindings.nextSpace) && interceptor.panelVisible {
      DispatchQueue.main.async {
        interceptor.delegate?.keyInterceptorJumpToNextSpace()
      }
      return nil  // consume
    }

    // Previous space (Cmd held)
    if cmdHeld && keyCode == Int64(bindings.previousSpace) && interceptor.panelVisible {
      DispatchQueue.main.async {
        interceptor.delegate?.keyInterceptorJumpToPreviousSpace()
      }
      return nil  // consume
    }

    // Down arrow (no Cmd) — jump to next space
    if !cmdHeld && keyCode == 125 && interceptor.panelVisible {
      DispatchQueue.main.async {
        interceptor.delegate?.keyInterceptorJumpToNextSpace()
      }
      return nil  // consume
    }

    // Up arrow (no Cmd) — jump to previous space
    if !cmdHeld && keyCode == 126 && interceptor.panelVisible {
      DispatchQueue.main.async {
        interceptor.delegate?.keyInterceptorJumpToPreviousSpace()
      }
      return nil  // consume
    }

    // Rename space
    if cmdHeld && keyCode == Int64(bindings.renameSpace) && interceptor.panelVisible {
      DispatchQueue.main.async {
        interceptor.delegate?.keyInterceptorStartRename()
      }
      return nil  // consume
    }

    // Close window (Cmd+W) or close space (Cmd+Shift+W)
    if cmdHeld && keyCode == Int64(bindings.closeWindow) && interceptor.panelVisible {
      if flags.contains(.maskShift) {
        DispatchQueue.main.async {
          interceptor.delegate?.keyInterceptorCloseSpace()
        }
        return nil  // consume
      }
      DispatchQueue.main.async {
        interceptor.delegate?.keyInterceptorCloseWindow()
      }
      return nil  // consume
    }

    // Quit app
    if cmdHeld && keyCode == Int64(bindings.quitApp) && interceptor.panelVisible {
      DispatchQueue.main.async {
        interceptor.delegate?.keyInterceptorQuitApp()
      }
      return nil  // consume
    }

    // Cycle sort order
    if cmdHeld && keyCode == Int64(bindings.cycleSortOrder) && interceptor.panelVisible {
      DispatchQueue.main.async {
        interceptor.delegate?.keyInterceptorCycleSortOrder()
      }
      return nil  // consume
    }

    // Create default spaces
    if cmdHeld && keyCode == Int64(bindings.createDefaultSpaces) && interceptor.panelVisible {
      DispatchQueue.main.async {
        interceptor.delegate?.keyInterceptorCreateDefaultSpaces()
      }
      return nil  // consume
    }

    // Cmd+Comma (keyCode 43) — open settings
    if cmdHeld && keyCode == 43 && interceptor.panelVisible {
      DispatchQueue.main.async {
        interceptor.delegate?.keyInterceptorOpenSettings()
      }
      return nil  // consume
    }

    // Next display
    if cmdHeld && keyCode == Int64(bindings.nextDisplay) && interceptor.panelVisible {
      DispatchQueue.main.async {
        interceptor.delegate?.keyInterceptorCycleDisplayRight()
      }
      return nil  // consume
    }

    // Previous display
    if cmdHeld && keyCode == Int64(bindings.previousDisplay) && interceptor.panelVisible {
      DispatchQueue.main.async {
        interceptor.delegate?.keyInterceptorCycleDisplayLeft()
      }
      return nil  // consume
    }

    // Cancel
    if keyCode == Int64(bindings.cancel) && interceptor.panelVisible {
      DispatchQueue.main.async {
        interceptor.delegate?.keyInterceptorCancel()
      }
      return nil  // consume
    }

  case .flagsChanged:
    // In rename mode, pass through modifier changes without confirming
    if interceptor.renameMode {
      return Unmanaged.passUnretained(event)
    }

    // Cmd released — if panel is visible, confirm selection
    // (suppressed during space create/close operations)
    if interceptor.panelVisible && !flags.contains(.maskCommand) {
      if interceptor.suppressConfirm {
        interceptor.suppressConfirm = false
        return Unmanaged.passUnretained(event)
      }
      DispatchQueue.main.async {
        interceptor.delegate?.keyInterceptorConfirm()
      }
      return Unmanaged.passUnretained(event)  // don't consume modifier release
    }

  default:
    break
  }

  return Unmanaged.passUnretained(event)
}
