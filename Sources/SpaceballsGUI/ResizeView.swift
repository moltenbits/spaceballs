import SpaceballsCore
import SpaceballsGUILib
import SwiftUI

struct ResizeView: View {
  @ObservedObject var viewModel: ResizeViewModel
  @ObservedObject var settings: AppSettings
  var displayUUID: String?

  private var isTargetDisplay: Bool {
    displayUUID == viewModel.targetDisplayUUID
  }

  var body: some View {
    VStack(spacing: 12) {
      // Header — focused app icon + name
      HStack(spacing: 8) {
        if let icon = viewModel.focusedAppIcon {
          Image(nsImage: icon)
            .resizable()
            .frame(width: 32, height: 32)
        }
        Text(viewModel.focusedAppName)
          .font(.headline)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer()
      }

      // Interactive grid — use active region's grid if a preset was applied
      ResizeGridView(
        columns: viewModel.activeRegion?.gridColumns ?? settings.resizeGridColumns,
        rows: viewModel.activeRegion?.gridRows ?? settings.resizeGridRows,
        highlightedRegion: isTargetDisplay ? viewModel.activeRegion : nil,
        onPreviewChanged: { region in
          if region != nil, displayUUID != viewModel.targetDisplayUUID {
            viewModel.setTargetDisplay(displayUUID)
          }
          viewModel.previewRegion = region
        }
      ) { region in
        viewModel.previewRegion = nil
        if displayUUID != viewModel.targetDisplayUUID {
          viewModel.setTargetDisplay(displayUUID)
        }
        viewModel.applyRegion(region, margins: CGFloat(settings.resizeMargins))
      }
    }
    .padding(16)
    .frame(width: 280)
    .background(
      VibrancyBackground()
        .clipShape(RoundedRectangle(cornerRadius: 12))
    )
  }
}

// MARK: - Interactive Grid

struct ResizeGridView: View {
  let columns: Int
  let rows: Int
  var highlightedRegion: GridRegion?
  var onPreviewChanged: ((GridRegion?) -> Void)?
  let onRegionSelected: (GridRegion) -> Void

  @State private var dragStart: (col: Int, row: Int)?
  @State private var dragCurrent: (col: Int, row: Int)?

  private var selectedRange: (minCol: Int, maxCol: Int, minRow: Int, maxRow: Int)? {
    // Drag selection takes priority over preset highlight
    if let start = dragStart, let current = dragCurrent {
      return (
        minCol: min(start.col, current.col),
        maxCol: max(start.col, current.col),
        minRow: min(start.row, current.row),
        maxRow: max(start.row, current.row)
      )
    }
    // Show preset highlight when not dragging
    if let r = highlightedRegion {
      return (
        minCol: r.column,
        maxCol: r.column + r.columnSpan - 1,
        minRow: r.row,
        maxRow: r.row + r.rowSpan - 1
      )
    }
    return nil
  }

  var body: some View {
    GeometryReader { geo in
      Canvas { context, size in
        let cellW = size.width / CGFloat(columns)
        let cellH = size.height / CGFloat(rows)
        let gap: CGFloat = 2
        let cornerRadius: CGFloat = 3

        for row in 0..<rows {
          for col in 0..<columns {
            let rect = CGRect(
              x: CGFloat(col) * cellW + gap / 2,
              y: CGFloat(row) * cellH + gap / 2,
              width: cellW - gap,
              height: cellH - gap
            )

            let isSelected: Bool
            if let sel = selectedRange {
              isSelected =
                col >= sel.minCol && col <= sel.maxCol
                && row >= sel.minRow && row <= sel.maxRow
            } else {
              isSelected = false
            }

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
            // Publish live preview
            if let start = dragStart {
              let sel = (
                minCol: min(start.col, col), maxCol: max(start.col, col),
                minRow: min(start.row, row), maxRow: max(start.row, row)
              )
              onPreviewChanged?(GridRegion(
                column: sel.minCol, row: sel.minRow,
                columnSpan: sel.maxCol - sel.minCol + 1,
                rowSpan: sel.maxRow - sel.minRow + 1,
                gridColumns: columns, gridRows: rows
              ))
            }
          }
          .onEnded { _ in
            if let sel = selectedRange {
              let region = GridRegion(
                column: sel.minCol,
                row: sel.minRow,
                columnSpan: sel.maxCol - sel.minCol + 1,
                rowSpan: sel.maxRow - sel.minRow + 1,
                gridColumns: columns,
                gridRows: rows
              )
              onRegionSelected(region)
            }
            onPreviewChanged?(nil)
            dragStart = nil
            dragCurrent = nil
          }
      )
    }
    .aspectRatio(CGFloat(columns) / CGFloat(rows), contentMode: .fit)
    .contentShape(Rectangle())
  }
}

// MARK: - Helpers

private func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int {
  min(max(value, low), high)
}

