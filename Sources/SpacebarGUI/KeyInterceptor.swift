import Cocoa

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

  func setPanelVisible(_ visible: Bool) {
    panelVisible = visible
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
      print("Try removing and re-adding Spacebar in System Settings → Privacy & Security → Accessibility.")
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

  let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
  let flags = event.flags

  switch type {
  case .keyDown:
    let cmdHeld = flags.contains(.maskCommand)

    // Cmd+Tab (keyCode 48)
    if cmdHeld && keyCode == 48 {
      DispatchQueue.main.async {
        if !interceptor.panelVisible {
          interceptor.delegate?.keyInterceptorShowPanel()
        }
        interceptor.delegate?.keyInterceptorMoveDown()
      }
      return nil  // consume
    }

    // Cmd+` (keyCode 50)
    if cmdHeld && keyCode == 50 {
      DispatchQueue.main.async {
        if interceptor.panelVisible {
          interceptor.delegate?.keyInterceptorMoveUp()
        }
      }
      return nil  // consume
    }

    // Cmd+W (keyCode 13) — close selected window
    if cmdHeld && keyCode == 13 && interceptor.panelVisible {
      DispatchQueue.main.async {
        interceptor.delegate?.keyInterceptorCloseWindow()
      }
      return nil  // consume
    }

    // Cmd+Q (keyCode 12) — quit selected app
    if cmdHeld && keyCode == 12 && interceptor.panelVisible {
      DispatchQueue.main.async {
        interceptor.delegate?.keyInterceptorQuitApp()
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

    // Escape (keyCode 53)
    if keyCode == 53 && interceptor.panelVisible {
      DispatchQueue.main.async {
        interceptor.delegate?.keyInterceptorCancel()
      }
      return nil  // consume
    }

  case .flagsChanged:
    // Cmd released — if panel is visible, confirm selection
    if interceptor.panelVisible && !flags.contains(.maskCommand) {
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
