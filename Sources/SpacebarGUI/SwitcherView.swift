import SpacebarGUILib
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
    let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
    var maxWidth: CGFloat = 0
    for section in visibleSections where !section.windows.isEmpty {
      let label = buildSpaceLabel(section)
      let size = (label as NSString).size(withAttributes: [.font: font])
      maxWidth = max(maxWidth, size.width)
    }
    return max(ceil(maxWidth) + 4, 80)
  }

  var body: some View {
    ZStack {
      ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: false) {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(visibleSections) { section in
              sectionContent(section)
            }
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

      // Scroll indicators — fixed overlays at panel edges
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
    .fixedSize(horizontal: true, vertical: false)
    .background(
      ZStack {
        VibrancyBackground()
        Color(nsColor: .controlBackgroundColor)
      }
    )
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .preferredColorScheme(preferredColorScheme)
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
        Image(systemName: "gearshape")
          .resizable()
          .frame(width: gearSize, height: gearSize)
          .frame(width: iconFrame, height: iconFrame)
          .foregroundStyle(.secondary)
        Text("Settings")
          .font(.system(size: CGFloat(appSettings.textSize)))
          .foregroundStyle(.secondary)
      }
      .padding(.vertical, 1)
      .padding(.horizontal, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        viewModel.selectedItem == .settings
          ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.8))
          : nil
      )
    }
    .id("settings")
    .contentShape(Rectangle())
  }

  // MARK: - Section Content

  private func buildSpaceLabel(_ section: SwitcherSection) -> String {
    var label = section.label
    if appSettings.showCurrentBadge && !section.ordinalLabel.isEmpty
      && section.ordinalLabel != section.label
    {
      label += " (\(section.ordinalLabel))"
    }
    if appSettings.showDisplayBadge && !appSettings.filterSpacesByDisplay
      && !section.displayName.isEmpty
    {
      label += " — \(section.displayName)"
    }
    return label
  }

  @ViewBuilder
  private func sectionContent(_ section: SwitcherSection) -> some View {
    let isRenamingThisSection = viewModel.renamingSpaceID == section.id

    if section.windows.isEmpty {
      // Empty space — standalone header
      SectionHeaderView(
        label: section.label,
        isCurrent: section.isCurrent,
        isSelected: viewModel.selectedItem == .spaceHeader(section.id),
        isEmpty: true,
        showOrdinalBadge: appSettings.showCurrentBadge,
        ordinalLabel: section.ordinalLabel,
        displayName: appSettings.showDisplayBadge && !appSettings.filterSpacesByDisplay
          ? section.displayName : "",
        textSize: CGFloat(appSettings.textSize),
        isRenaming: isRenamingThisSection,
        renameText: isRenamingThisSection ? $viewModel.renameText : .constant("")
      )
      .id("header-\(section.id)")
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
