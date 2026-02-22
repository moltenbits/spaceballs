import SpacebarGUILib
import SwiftUI

struct SwitcherRowView: View {
  let row: SwitcherRow
  let isSelected: Bool
  var showAppIcon: Bool = true
  var textSize: CGFloat = 13
  var iconSize: CGFloat = 20

  private var pinSize: CGFloat { round(textSize * 9.0 / 13.0) }

  var body: some View {
    HStack(spacing: 8) {
      // App name — right-aligned in a fixed-width column
      Text(row.appName)
        .font(.system(size: textSize))
        .foregroundStyle(.secondary)
        .frame(width: 110, alignment: .trailing)
        .lineLimit(1)

      // App icon
      if showAppIcon {
        if let icon = row.appIcon {
          Image(nsImage: icon)
            .resizable()
            .frame(width: iconSize, height: iconSize)
        } else {
          Image(systemName: "app.fill")
            .resizable()
            .frame(width: iconSize, height: iconSize)
            .foregroundStyle(.secondary)
        }
      }

      // Window title
      Text(row.windowTitle.isEmpty ? row.appName : row.windowTitle)
        .font(.system(size: textSize))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: 400, alignment: .leading)

      if row.isSticky {
        Image(systemName: "pin.fill")
          .font(.system(size: pinSize))
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
  var isSelected: Bool = false
  var isEmpty: Bool = false
  var showCurrentBadge: Bool = true
  var displayName: String = ""
  var textSize: CGFloat = 13
  var isRenaming: Bool = false
  var renameText: Binding<String> = .constant("")

  @FocusState private var isTextFieldFocused: Bool

  private var headerSize: CGFloat { round(textSize * 11.0 / 13.0) }
  private var badgeSize: CGFloat { round(textSize * 10.0 / 13.0) }

  var body: some View {
    HStack(spacing: 4) {
      if isRenaming {
        TextField("Space name", text: renameText)
          .font(.system(size: headerSize, weight: .semibold))
          .textFieldStyle(.plain)
          .focused($isTextFieldFocused)
          .onAppear { isTextFieldFocused = true }
      } else {
        Text(label)
          .font(.system(size: headerSize, weight: .semibold))
          .foregroundStyle(isSelected ? .primary : .secondary)

        if isCurrent && showCurrentBadge {
          Text("(current)")
            .font(.system(size: badgeSize))
            .foregroundStyle(isSelected ? .secondary : .tertiary)
        }

        if isEmpty {
          Text("(no windows)")
            .font(.system(size: badgeSize))
            .foregroundStyle(isSelected ? .secondary : .tertiary)
        }

        if !displayName.isEmpty {
          Text("— \(displayName)")
            .font(.system(size: badgeSize))
            .foregroundStyle(isSelected ? .secondary : .tertiary)
        }
      }
    }
    .padding(.vertical, 2)
    .padding(.horizontal, 10)
    .padding(.top, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      isSelected
        ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.8))
        : nil
    )
    .contentShape(Rectangle())
  }
}
