import SpaceballsCore
import SpaceballsGUILib
import SwiftUI

struct ResizePane: View {
  @ObservedObject var settings: AppSettings
  @State private var expandedPresetID: UUID?

  var body: some View {
    Form {
      Section("Grid") {
        Stepper(
          "Columns: \(settings.resizeGridColumns)", value: $settings.resizeGridColumns,
          in: 1...(.max))
        Stepper("Rows: \(settings.resizeGridRows)", value: $settings.resizeGridRows, in: 1...(.max))
        Text("Press ⇧⌘D to open the resize grid.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Margins") {
        LabeledContent("Window gap") {
          HStack {
            Slider(value: $settings.resizeMargins, in: 0...20, step: 1)
            Text("\(Int(settings.resizeMargins))px")
              .monospacedDigit()
              .frame(width: 36, alignment: .trailing)
          }
        }
      }

      Section("Presets") {
        Text("Shortcuts are active while the resize grid is open.")
          .font(.caption)
          .foregroundStyle(.secondary)

        ForEach($settings.resizePresets) { $preset in
          PresetEditor(
            preset: $preset,
            expandedPresetID: $expandedPresetID,
            isRecording: $settings.isRecordingShortcut,
            onDelete: {
              if expandedPresetID == preset.id { expandedPresetID = nil }
              settings.resizePresets.removeAll { $0.id == preset.id }
            }
          )
        }

        Button("Add Preset") {
          let newPreset = ResizePreset(
            name: "New Preset",
            region: GridRegion(
              column: 0, row: 0,
              columnSpan: settings.resizeGridColumns,
              rowSpan: settings.resizeGridRows,
              gridColumns: settings.resizeGridColumns,
              gridRows: settings.resizeGridRows
            )
          )
          settings.resizePresets.append(newPreset)
          expandedPresetID = newPreset.id
        }
      }

      Section {
        Button("Restore Default Presets") {
          settings.resizePresets = ResizePreset.defaultPresets(
            gridColumns: settings.resizeGridColumns,
            gridRows: settings.resizeGridRows
          )
        }
      }
    }
    .formStyle(.grouped)
  }
}

// MARK: - Preset Editor

private struct PresetEditor: View {
  @Binding var preset: ResizePreset
  @Binding var expandedPresetID: UUID?
  @Binding var isRecording: Bool
  let onDelete: () -> Void

  @FocusState private var nameFieldFocused: Bool

  private var isExpanded: Bool { expandedPresetID == preset.id }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header row — clickable to expand/collapse
      Button {
        withAnimation {
          expandedPresetID = isExpanded ? nil : preset.id
        }
      } label: {
        HStack(spacing: 10) {
          Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .frame(width: 16)

          MiniGridPreview(
            region: preset.region,
            columns: preset.region.gridColumns,
            rows: preset.region.gridRows
          )
          .frame(width: 48, height: 36)

          Text(preset.name)
            .font(.headline)

          Spacer()

          if let keyCode = preset.keyCode {
            Text(KeyCodeNames.displayName(for: keyCode))
              .font(.caption)
              .foregroundStyle(.secondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(
                RoundedRectangle(cornerRadius: 4)
                  .fill(Color.primary.opacity(0.08))
              )
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      // Expanded content
      if isExpanded {
        VStack(alignment: .leading, spacing: 10) {
          HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
              Text("Name")
                .font(.caption)
                .foregroundStyle(.secondary)
              TextField("", text: $preset.name)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .focused($nameFieldFocused)
                .onAppear {
                  DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    nameFieldFocused = true
                    // Select all text in the focused text field
                    if let editor = NSApp.keyWindow?.firstResponder as? NSText {
                      editor.selectAll(nil)
                    }
                  }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
              Text("Shortcut")
                .font(.caption)
                .foregroundStyle(.secondary)
              OptionalKeyRecorderView(
                keyCode: $preset.keyCode,
                isRecording: $isRecording
              )
              .frame(width: 100)
            }
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Region")
              .font(.caption)
              .foregroundStyle(.secondary)
            PresetGridEditor(
              region: $preset.region,
              columns: preset.region.gridColumns,
              rows: preset.region.gridRows
            )
          }

          HStack {
            Spacer()
            Button("Delete Preset", role: .destructive) {
              onDelete()
            }
            .foregroundStyle(.red)
          }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
      }
    }
  }
}

// MARK: - Optional Key Recorder

/// Wraps KeyRecorderView to support an optional key code.
/// Click to record a new shortcut; press Escape or Delete while recording to clear it.
private struct OptionalKeyRecorderView: View {
  @Binding var keyCode: UInt16?
  @Binding var isRecording: Bool

  var body: some View {
    OptionalKeyRecorderNSViewRepresentable(
      keyCode: $keyCode,
      isRecording: $isRecording
    )
  }
}

private struct OptionalKeyRecorderNSViewRepresentable: NSViewRepresentable {
  @Binding var keyCode: UInt16?
  @Binding var isRecording: Bool

  func makeNSView(context: Context) -> OptionalKeyRecorderNSView {
    let view = OptionalKeyRecorderNSView()
    view.keyCode = keyCode
    view.onKeyRecorded = { newCode in
      keyCode = newCode
      isRecording = false
    }
    view.onKeyCleared = {
      keyCode = nil
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

  func updateNSView(_ nsView: OptionalKeyRecorderNSView, context: Context) {
    nsView.keyCode = keyCode
    nsView.updateDisplay()
  }
}

final class OptionalKeyRecorderNSView: NSView {
  var keyCode: UInt16?
  var onKeyRecorded: ((UInt16) -> Void)?
  var onKeyCleared: (() -> Void)?
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
    } else if let code = keyCode {
      label.stringValue = KeyCodeNames.displayName(for: code)
      label.textColor = .labelColor
      layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
      layer?.borderColor = NSColor.separatorColor.cgColor
    } else {
      label.stringValue = "Click to record"
      label.textColor = .tertiaryLabelColor
      layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
      layer?.borderColor = NSColor.separatorColor.cgColor
    }
  }

  override var acceptsFirstResponder: Bool { true }

  override func mouseDown(with event: NSEvent) {
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

    // Delete/Backspace clears the shortcut
    if code == 51 || code == 117 {
      recording = false
      onKeyCleared?()
      updateDisplay()
      return
    }

    // Record the key
    recording = false
    keyCode = code
    onKeyRecorded?(code)
    updateDisplay()
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if recording {
      keyDown(with: event)
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}

// MARK: - Preset Grid Editor

/// An interactive grid for defining a preset's region by click-dragging.
private struct PresetGridEditor: View {
  @Binding var region: GridRegion
  let columns: Int
  let rows: Int

  @State private var dragStart: (col: Int, row: Int)?
  @State private var dragCurrent: (col: Int, row: Int)?

  private var liveRange: (minCol: Int, maxCol: Int, minRow: Int, maxRow: Int)? {
    guard let start = dragStart, let current = dragCurrent else { return nil }
    return (
      minCol: min(start.col, current.col),
      maxCol: max(start.col, current.col),
      minRow: min(start.row, current.row),
      maxRow: max(start.row, current.row)
    )
  }

  /// The range to display — live drag if active, otherwise the saved region.
  private var displayRange: (minCol: Int, maxCol: Int, minRow: Int, maxRow: Int) {
    if let live = liveRange { return live }
    return (
      minCol: region.column,
      maxCol: region.column + region.columnSpan - 1,
      minRow: region.row,
      maxRow: region.row + region.rowSpan - 1
    )
  }

  var body: some View {
    GeometryReader { geo in
      Canvas { context, size in
        let cellW = size.width / CGFloat(columns)
        let cellH = size.height / CGFloat(rows)
        let gap: CGFloat = 2
        let cornerRadius: CGFloat = 3
        let sel = displayRange

        for row in 0..<rows {
          for col in 0..<columns {
            let rect = CGRect(
              x: CGFloat(col) * cellW + gap / 2,
              y: CGFloat(row) * cellH + gap / 2,
              width: cellW - gap,
              height: cellH - gap
            )

            let isSelected =
              col >= sel.minCol && col <= sel.maxCol
              && row >= sel.minRow && row <= sel.maxRow

            let path = RoundedRectangle(cornerRadius: cornerRadius).path(in: rect)
            if isSelected {
              context.fill(path, with: .color(.accentColor.opacity(0.8)))
            } else {
              context.fill(path, with: .color(.primary.opacity(0.15)))
            }
          }
        }
      }
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            let cellW = geo.size.width / CGFloat(columns)
            let cellH = geo.size.height / CGFloat(rows)
            let col = clamp(Int(value.location.x / cellW), 0, columns - 1)
            let row = clamp(Int(value.location.y / cellH), 0, rows - 1)

            if dragStart == nil {
              let startCol = clamp(Int(value.startLocation.x / cellW), 0, columns - 1)
              let startRow = clamp(Int(value.startLocation.y / cellH), 0, rows - 1)
              dragStart = (startCol, startRow)
            }
            dragCurrent = (col, row)
          }
          .onEnded { _ in
            if let sel = liveRange {
              region = GridRegion(
                column: sel.minCol,
                row: sel.minRow,
                columnSpan: sel.maxCol - sel.minCol + 1,
                rowSpan: sel.maxRow - sel.minRow + 1,
                gridColumns: columns,
                gridRows: rows
              )
            }
            dragStart = nil
            dragCurrent = nil
          }
      )
    }
    .aspectRatio(CGFloat(columns) / CGFloat(rows), contentMode: .fit)
    .contentShape(Rectangle())
  }
}

// MARK: - Mini Grid Preview

struct MiniGridPreview: View {
  let region: GridRegion
  let columns: Int
  let rows: Int

  var body: some View {
    Canvas { context, size in
      let cellW = size.width / CGFloat(columns)
      let cellH = size.height / CGFloat(rows)
      let gap: CGFloat = 1
      let cornerRadius: CGFloat = 1.5

      for row in 0..<rows {
        for col in 0..<columns {
          let rect = CGRect(
            x: CGFloat(col) * cellW + gap / 2,
            y: CGFloat(row) * cellH + gap / 2,
            width: cellW - gap,
            height: cellH - gap
          )

          let isSelected =
            col >= region.column && col < region.column + region.columnSpan
            && row >= region.row && row < region.row + region.rowSpan

          let path = RoundedRectangle(cornerRadius: cornerRadius).path(in: rect)
          if isSelected {
            context.fill(path, with: .color(.accentColor.opacity(0.8)))
          } else {
            context.fill(path, with: .color(.primary.opacity(0.15)))
          }
        }
      }
    }
  }
}

// MARK: - Helpers

private func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int {
  min(max(value, low), high)
}
