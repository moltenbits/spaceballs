import SpacebarGUILib
import SwiftUI

struct SwitcherRowView: View {
  let row: SwitcherRow
  let isSelected: Bool

  var body: some View {
    HStack(spacing: 8) {
      // App name — right-aligned in a fixed-width column
      Text(row.appName)
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .frame(width: 110, alignment: .trailing)
        .lineLimit(1)

      // App icon
      if let icon = row.appIcon {
        Image(nsImage: icon)
          .resizable()
          .frame(width: 20, height: 20)
      } else {
        Image(systemName: "app.fill")
          .resizable()
          .frame(width: 20, height: 20)
          .foregroundStyle(.secondary)
      }

      // Window title
      Text(row.windowTitle.isEmpty ? row.appName : row.windowTitle)
        .font(.system(size: 13))
        .foregroundStyle(.primary)
        .lineLimit(1)

      if row.isSticky {
        Image(systemName: "pin.fill")
          .font(.system(size: 9))
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.vertical, 1)
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      isSelected
        ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.8))
        : nil
    )
    .contentShape(Rectangle())
  }
}

// MARK: - Section Header

struct SectionHeaderView: View {
  let label: String
  let isCurrent: Bool

  var body: some View {
    HStack(spacing: 4) {
      Text(label)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)

      if isCurrent {
        Text("(current)")
          .font(.system(size: 10))
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.leading, 10)
    .padding(.top, 6)
    .padding(.bottom, 2)
  }
}
