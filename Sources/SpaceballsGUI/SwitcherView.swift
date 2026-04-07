import SpaceballsGUILib
import SwiftUI

struct SwitcherView: View {
  @ObservedObject var viewModel: SwitcherViewModel
  @ObservedObject var appSettings: AppSettings
  var displayUUID: String?
  var contentOverflows: Bool = false
  /// Approximate number of items that fit in the visible panel area.
  var visibleCapacity: Int = 0

  private var preferredColorScheme: ColorScheme? {
    switch appSettings.colorScheme {
    case .auto: nil
    case .light: .light
    case .dark: .dark
    }
  }

  private var visibleSections: [SwitcherSection] {
    guard let uuid = displayUUID else { return viewModel.filteredSections }
    return viewModel.filteredSections.filter { $0.displayUUID == uuid }
  }

  /// Converts the current selection into a hashable scroll anchor ID.
  private var scrollAnchor: AnyHashable? {
    switch viewModel.selectedItem {
    case .windowRow(let id): AnyHashable(id)
    case .spaceHeader(let id): AnyHashable("header-\(id)")
    case .spaces: AnyHashable("spaces")
    case .settings: AnyHashable("settings")
    case nil: nil
    }
  }

  /// All selectable items visible in THIS panel (not the global flat list).
  private var localSelectableItems: [SelectedItem] {
    var items: [SelectedItem] = []
    for section in visibleSections {
      if section.windows.isEmpty {
        items.append(.spaceHeader(section.id))
      } else {
        for row in section.windows {
          items.append(.windowRow(row.id))
        }
      }
    }
    items.append(.spaces)
    items.append(.settings)
    return items
  }

  /// How far the selection must be from the top/bottom edge before the
  /// `scrollTo(anchor: .center)` actually causes the list to scroll.
  private var scrollThreshold: Int {
    max(visibleCapacity / 2, 1)
  }

  private var showTopArrow: Bool {
    guard contentOverflows else { return false }
    guard let item = viewModel.selectedItem else { return false }
    let items = localSelectableItems
    guard let idx = items.firstIndex(of: item) else { return false }
    return idx >= scrollThreshold
  }

  private var showBottomArrow: Bool {
    guard contentOverflows else { return false }
    guard let item = viewModel.selectedItem else { return true }
    let items = localSelectableItems
    guard let idx = items.firstIndex(of: item) else { return true }
    return idx <= items.count - 1 - scrollThreshold
  }

  /// Computed width for the space label column — just wide enough for the
  /// longest label across all visible sections so every row aligns.
  private var spaceLabelWidth: CGFloat {
    let fontSize = round(CGFloat(appSettings.textSize) * 11.0 / 13.0)
    let boldFont = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
    let regularFont = NSFont.systemFont(ofSize: fontSize, weight: .regular)
    var maxWidth: CGFloat = 0
    for section in visibleSections {
      let label = buildSpaceLabel(section)
      var width = (label as NSString).size(withAttributes: [.font: boldFont]).width
      if let badge = buildSpaceBadge(section) {
        width += 4 + (badge as NSString).size(withAttributes: [.font: regularFont]).width
      }
      maxWidth = max(maxWidth, width)
    }
    return max(ceil(maxWidth) + 4, 80)
  }

  var body: some View {
    ZStack {
      if viewModel.panelMode == .createSpace {
        createSpaceMenu
      } else {
        normalContent
      }

      // Scroll indicators — fixed overlays at panel edges (normal mode only)
      if viewModel.panelMode == .normal {
        VStack(spacing: 0) {
          if showTopArrow {
            scrollArrow(direction: .up)
          }
          Spacer()
          if showBottomArrow {
            scrollArrow(direction: .down)
          }
        }
      }

      // Sort order toast overlay
      SortOrderToast(text: viewModel.sortOverlayText ?? "")
        .opacity(viewModel.sortOverlayText != nil ? 1 : 0)
        .animation(
          .easeOut(duration: viewModel.sortOverlayText != nil ? 0.15 : 0.4),
          value: viewModel.sortOverlayText)
    }
    .fixedSize(horizontal: viewModel.panelMode == .normal, vertical: false)
    .background(
      ZStack {
        VibrancyBackground()
        Color(nsColor: .controlBackgroundColor)
      }
    )
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .preferredColorScheme(preferredColorScheme)
    .onChange(of: viewModel.sortOverlayGeneration) { _, gen in
      if viewModel.sortOverlayText != nil {
        let captured = gen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
          if viewModel.sortOverlayGeneration == captured {
            viewModel.sortOverlayText = nil
          }
        }
      }
    }
  }

  // MARK: - Normal Content

  private var normalContent: some View {
    Group {
      ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: false) {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(visibleSections) { section in
              sectionContent(section)
            }
            spacesRow
            settingsRow
          }
          .padding(.top, contentOverflows ? 20 : 6)
          .padding(.bottom, contentOverflows ? 20 : 10)
          .padding(.horizontal, 6)
        }
        .onChange(of: scrollAnchor) { _, anchor in
          if let anchor {
            withAnimation(.easeOut(duration: 0.15)) {
              proxy.scrollTo(anchor, anchor: .center)
            }
          }
        }
      }
    }
  }

  // MARK: - Create Space Menu

  private var createSpaceMenu: some View {
    let textSize = CGFloat(appSettings.textSize)
    let labelSize = round(textSize * 11.0 / 13.0)

    return ScrollView(.vertical, showsIndicators: false) {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(viewModel.createMenuItems) { item in
          let isSelected = viewModel.createMenuSelection == item.id
          let isBack = item.workspaceIndex == SwitcherViewModel.backWorkspaceIndex
          let isNewSpace = item.workspaceIndex == nil
          let isFirstRestore = item.id == 2
          let isAllSpaces = item.workspaceIndex == SwitcherViewModel.allSpacesWorkspaceIndex

          if isFirstRestore || isAllSpaces {
            Spacer().frame(height: 4)
          }

          HStack(spacing: 8) {
            // Left column — matches spaceLabelView position
            Group {
              if isBack {
                Text("Back...")
                  .font(.system(size: labelSize, weight: .semibold))
                  .foregroundStyle(isSelected ? .primary : .secondary)
              } else if isNewSpace {
                Text("Create...")
                  .font(.system(size: labelSize, weight: .semibold))
                  .foregroundStyle(isSelected ? .primary : .secondary)
              } else if isFirstRestore {
                Text("Restore...")
                  .font(.system(size: labelSize, weight: .semibold))
                  .foregroundStyle(isSelected ? .primary : .secondary)
              } else {
                Text("")
              }
            }
            .frame(width: spaceLabelWidth, alignment: .leading)

          if isBack {
            // Empty right side to match row height
            Text("")
              .frame(width: 110, alignment: .trailing)
            Spacer()
              .frame(width: appSettings.iconSize, height: appSettings.iconSize)
          } else {

            // Matches the 110pt app name column
            Text(item.label)
              .font(.system(size: textSize))
              .foregroundStyle(isSelected ? .white : .secondary)
              .frame(width: 110, alignment: .trailing)
              .lineLimit(1)

            // Matches the icon position
            if isNewSpace {
              Image(systemName: "plus.square")
                .resizable()
                .frame(width: appSettings.iconSize, height: appSettings.iconSize)
                .foregroundStyle(isSelected ? .white : .secondary)
            } else {
              Image(systemName: "square.grid.2x2")
                .resizable()
                .frame(width: appSettings.iconSize, height: appSettings.iconSize)
                .foregroundStyle(isSelected ? .white : .secondary)
            }

            // Right column — app summary or label
            if let wsIdx = item.workspaceIndex, wsIdx >= 0,
              wsIdx < appSettings.workspaces.count
            {
              let apps = appSettings.workspaces[wsIdx].launchers
              let names = apps.prefix(4).compactMap { l in
                l.appName.isEmpty ? nil : l.appName
              }
              Text(names.isEmpty ? item.label : names.joined(separator: ", "))
                .font(.system(size: textSize))
                .foregroundStyle(isSelected ? .white : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 400, alignment: .leading)
            } else {
              Text(isNewSpace ? "Empty space" : item.label)
                .font(.system(size: textSize))
                .foregroundStyle(isSelected ? .white : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 400, alignment: .leading)
            }
          } // end if isBack/else
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
          .padding(.top, item.id == 0 ? 4 : 0)
        }
      }
      .padding(.top, contentOverflows ? 20 : 6)
      .padding(.bottom, contentOverflows ? 20 : 10)
      .padding(.horizontal, 6)
    }
  }

  // MARK: - Scroll Arrow

  private enum ArrowDirection {
    case up, down
  }

  private func scrollArrow(direction: ArrowDirection) -> some View {
    let isUp = direction == .up
    return Image(systemName: isUp ? "chevron.compact.up" : "chevron.compact.down")
      .font(.system(size: 18, weight: .semibold))
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity)
      .frame(height: 20)
      .background(
        LinearGradient(
          colors: isUp
            ? [Color(nsColor: .controlBackgroundColor).opacity(0.95), .clear]
            : [.clear, Color(nsColor: .controlBackgroundColor).opacity(0.95)],
          startPoint: .top,
          endPoint: .bottom
        )
      )
      .allowsHitTesting(false)
  }

  // MARK: - Settings Row

  /// Whether this panel should show the highlight for .spaces/.settings
  private var isGlobalRowSelectedOnThisPanel: Bool {
    guard let uuid = displayUUID else { return true }  // single panel, always show
    return viewModel.contextDisplayUUID == uuid
  }

  private var spacesRow: some View {
    let iconSize = CGFloat(round(appSettings.textSize * 14.0 / 13.0))
    let iconFrame = appSettings.iconSize
    let isSelected = viewModel.selectedItem == .spaces && isGlobalRowSelectedOnThisPanel
    return VStack(spacing: 0) {
      Spacer().frame(height: 6)
      HStack(spacing: 8) {
        Text("")
          .frame(width: spaceLabelWidth, alignment: .leading)
        Text("")
          .frame(width: 110, alignment: .trailing)
        Image(systemName: "square.grid.2x2")
          .resizable()
          .frame(width: iconSize, height: iconSize)
          .frame(width: iconFrame, height: iconFrame)
          .foregroundStyle(isSelected ? .white : .secondary)
        Text("Spaces")
          .font(.system(size: CGFloat(appSettings.textSize)))
          .foregroundStyle(isSelected ? .white : .secondary)
      }
      .padding(.vertical, 1)
      .padding(.horizontal, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        isSelected
          ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.8))
          : nil
      )
    }
    .id("spaces")
    .contentShape(Rectangle())
  }

  private var settingsRow: some View {
    let gearSize = CGFloat(round(appSettings.textSize * 14.0 / 13.0))
    let iconFrame = appSettings.iconSize
    return VStack(spacing: 0) {
      Spacer().frame(height: 6)
      HStack(spacing: 8) {
        Text("")
          .frame(width: spaceLabelWidth, alignment: .leading)
        Text("")
          .frame(width: 110, alignment: .trailing)
        let isSettingsSelected =
          viewModel.selectedItem == .settings && isGlobalRowSelectedOnThisPanel
        Image(systemName: "gearshape")
          .resizable()
          .frame(width: gearSize, height: gearSize)
          .frame(width: iconFrame, height: iconFrame)
          .foregroundStyle(isSettingsSelected ? .white : .secondary)
        Text("Settings")
          .font(.system(size: CGFloat(appSettings.textSize)))
          .foregroundStyle(isSettingsSelected ? .white : .secondary)
      }
      .padding(.vertical, 1)
      .padding(.horizontal, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        viewModel.selectedItem == .settings && isGlobalRowSelectedOnThisPanel
          ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.8))
          : nil
      )
    }
    .id("settings")
    .contentShape(Rectangle())
  }

  // MARK: - Section Content

  private func buildSpaceLabel(_ section: SwitcherSection) -> String {
    section.label
  }

  private func buildSpaceBadge(_ section: SwitcherSection) -> String? {
    var badge = ""
    if appSettings.showCurrentBadge && !section.ordinalLabel.isEmpty
      && section.ordinalLabel != section.label
    {
      badge += "(\(section.ordinalLabel))"
    }
    if appSettings.showDisplayBadge && !appSettings.filterSpacesByDisplay
      && !section.displayName.isEmpty
    {
      if !badge.isEmpty { badge += " " }
      badge += "— \(section.displayName)"
    }
    return badge.isEmpty ? nil : badge
  }

  @ViewBuilder
  private func sectionContent(_ section: SwitcherSection) -> some View {
    let isRenamingThisSection = viewModel.renamingSpaceID == section.id

    if section.windows.isEmpty {
      // Empty space — same row layout as combined rows, with "no windows" placeholder
      emptySpaceRow(section, isRenaming: isRenamingThisSection)
        .id("header-\(section.id)")
        .padding(.top, 4)
        .onTapGesture {
          guard !viewModel.isRenaming else { return }
          viewModel.selectedItem = .spaceHeader(section.id)
          viewModel.activateSelected()
        }
    } else {
      // Non-empty space — first row gets the space label
      ForEach(Array(section.windows.enumerated()), id: \.element.id) { index, row in
        let isFirstRow = index == 0
        SwitcherRowView(
          row: row,
          isSelected: viewModel.selectedItem == .windowRow(row.id),
          showAppIcon: appSettings.showAppIcons,
          textSize: CGFloat(appSettings.textSize),
          iconSize: appSettings.iconSize,
          spaceLabel: isFirstRow ? buildSpaceLabel(section) : nil,
          spaceBadge: isFirstRow ? buildSpaceBadge(section) : nil,
          spaceLabelWidth: spaceLabelWidth,
          isRenaming: isFirstRow && isRenamingThisSection,
          renameText: (isFirstRow && isRenamingThisSection)
            ? $viewModel.renameText : .constant("")
        )
        .id(row.id)
        .padding(.top, isFirstRow ? 4 : 0)
        .onTapGesture {
          guard !viewModel.isRenaming else { return }
          viewModel.selectedItem = .windowRow(row.id)
          viewModel.activateSelected()
        }
      }
    }
  }
  // MARK: - Empty Space Row

  private func emptySpaceRow(
    _ section: SwitcherSection, isRenaming: Bool
  ) -> some View {
    let isSelected = viewModel.selectedItem == .spaceHeader(section.id)
    let headerSize = round(CGFloat(appSettings.textSize) * 11.0 / 13.0)
    let noWindowsSize = round(CGFloat(appSettings.textSize) * 12.0 / 13.0)
    return HStack(spacing: 8) {
      // Space label column — matches SwitcherRowView layout
      Group {
        if isRenaming {
          EmptySpaceRenameField(
            text: $viewModel.renameText,
            font: .system(size: headerSize, weight: .semibold)
          )
        } else {
          HStack(spacing: 4) {
            Text(buildSpaceLabel(section))
              .font(.system(size: headerSize, weight: .semibold))
              .foregroundStyle(isSelected ? .primary : .secondary)
            if let badge = buildSpaceBadge(section) {
              Text(badge)
                .font(.system(size: headerSize, weight: .regular))
                .foregroundStyle(.tertiary)
            }
          }
          .lineLimit(1)
        }
      }
      .frame(width: spaceLabelWidth, alignment: .leading)

      // "no windows" in the app content area
      Text("")
        .frame(width: 110, alignment: .trailing)
      Text("Empty")
        .font(.system(size: noWindowsSize))
        .foregroundStyle(.tertiary)
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

/// Separate view to hold @FocusState for the empty-space rename TextField.
private struct EmptySpaceRenameField: View {
  @Binding var text: String
  var font: Font

  @FocusState private var isFocused: Bool

  var body: some View {
    TextField("Space name", text: $text)
      .font(font)
      .textFieldStyle(.plain)
      .focused($isFocused)
      .onAppear { isFocused = true }
  }
}

// MARK: - Sort Order Toast

private struct SortOrderToast: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.system(size: 14, weight: .semibold))
      .foregroundColor(.white)
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .background(
        RoundedRectangle(cornerRadius: 8)
          .fill(Color.black.opacity(0.75))
      )
      .allowsHitTesting(false)
  }
}

// MARK: - Vibrancy Background

struct VibrancyBackground: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .hudWindow
    view.blendingMode = .behindWindow
    view.state = .active
    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
