import Cocoa
import SpacebarGUILib
import SwiftUI

struct KeyRecorderView: NSViewRepresentable {
  @Binding var keyCode: UInt16
  @Binding var isRecording: Bool
  @Environment(\.isEnabled) private var isEnabled

  func makeNSView(context: Context) -> KeyRecorderNSView {
    let view = KeyRecorderNSView()
    view.keyCode = keyCode
    view.isDisabled = !isEnabled
    view.onKeyRecorded = { newCode in
      keyCode = newCode
      isRecording = false
    }
    view.onRecordingStarted = {
      isRecording = true
    }
    view.onRecordingCancelled = {
      isRecording = false
    }
    return view
  }

  func updateNSView(_ nsView: KeyRecorderNSView, context: Context) {
    nsView.keyCode = keyCode
    nsView.isDisabled = !isEnabled
    nsView.updateDisplay()
  }
}

// MARK: - NSView

final class KeyRecorderNSView: NSView {
  var keyCode: UInt16 = 48
  var isDisabled = false
  var onKeyRecorded: ((UInt16) -> Void)?
  var onRecordingStarted: (() -> Void)?
  var onRecordingCancelled: (() -> Void)?

  private var recording = false
  private let label = NSTextField(labelWithString: "")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  private func setup() {
    wantsLayer = true
    layer?.cornerRadius = 6
    layer?.borderWidth = 1

    label.translatesAutoresizingMaskIntoConstraints = false
    label.alignment = .center
    label.font = .systemFont(ofSize: 12, weight: .medium)
    label.isEditable = false
    label.isSelectable = false
    label.isBezeled = false
    label.drawsBackground = false
    addSubview(label)

    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      heightAnchor.constraint(equalToConstant: 24),
      widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
    ])

    updateDisplay()
  }

  func updateDisplay() {
    if recording {
      label.stringValue = "Type shortcut"
      label.textColor = .selectedControlTextColor
      layer?.backgroundColor = NSColor.controlAccentColor.cgColor
      layer?.borderColor = NSColor.controlAccentColor.cgColor
    } else if isDisabled {
      label.stringValue = "⌘ " + KeyCodeNames.displayName(for: keyCode)
      label.textColor = .disabledControlTextColor
      layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.5).cgColor
      layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
    } else {
      label.stringValue = "⌘ " + KeyCodeNames.displayName(for: keyCode)
      label.textColor = .labelColor
      layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
      layer?.borderColor = NSColor.separatorColor.cgColor
    }
  }

  // MARK: - First Responder

  override var acceptsFirstResponder: Bool { true }

  override func mouseDown(with event: NSEvent) {
    guard !isDisabled else { return }
    if !recording {
      recording = true
      window?.makeFirstResponder(self)
      onRecordingStarted?()
      updateDisplay()
    }
  }

  override func resignFirstResponder() -> Bool {
    if recording {
      recording = false
      onRecordingCancelled?()
      updateDisplay()
    }
    return super.resignFirstResponder()
  }

  // MARK: - Key Capture

  override func keyDown(with event: NSEvent) {
    guard recording else {
      super.keyDown(with: event)
      return
    }

    let code = event.keyCode

    // Escape cancels recording
    if code == 53 {
      recording = false
      onRecordingCancelled?()
      updateDisplay()
      return
    }

    // Record the key
    recording = false
    keyCode = code
    onKeyRecorded?(code)
    updateDisplay()
  }

  // Prevent the system beep on key presses while recording
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if recording {
      keyDown(with: event)
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}
