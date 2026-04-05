import SpaceballsGUILib
import SwiftUI

struct SpacesPane: View {
  @ObservedObject var settings: AppSettings
  @State private var selection: Int? = nil
  @State private var editingIndex: Int? = nil
  @State private var editText: String = ""
  @State private var configuringIndex: Int? = nil

  private let listBg = Color(white: 0.97)
  private let footerBg = Color(white: 0.935)

  var body: some View {
    spacesListView
  }

  private var spacesListView: some View {
    VStack(spacing: 0) {
      // Description
      Text(
        "Define your workspaces. Each workspace maps to a macOS Space and can have apps configured to launch automatically."
      )
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .onTapGesture {
        if editingIndex != nil { commitEdit() }
        selection = nil
      }

      // Rows
      ForEach(Array(settings.workspaces.enumerated()), id: \.element.id) { index, workspace in
        Rectangle()
          .fill(Color.primary.opacity(0.05))
          .frame(height: 1)
        SpaceNameRow(
          name: workspace.name,
          launcherCount: workspace.launchers.count,
          isSelected: selection == index,
          isEditing: editingIndex == index,
          editText: $editText,
          onSingleClick: {
            if editingIndex != nil && editingIndex != index {
              commitEdit()
            }
            if editingIndex == index {
              // Already editing this row — do nothing
            } else if selection == index {
              // Already selected — enter edit mode
              beginEdit(index: index)
            } else {
              // Not selected — select it
              selection = index
            }
          },
          onCommit: { commitEdit() },
          onCancel: { cancelEdit() },
          onConfigure: { configuringIndex = index }
        )
      }

      Divider()

      // Footer
      HStack(spacing: 0) {
        Button(action: addRow) {
          Image(systemName: "plus")
            .frame(width: 30, height: 28)
        }
        .buttonStyle(.borderless)

        Divider().frame(height: 14)

        Button(action: removeSelected) {
          Image(systemName: "minus")
            .frame(width: 30, height: 28)
        }
        .buttonStyle(.borderless)
        .disabled(selection == nil)

        Divider().frame(height: 14)

        Button(action: moveUp) {
          Image(systemName: "chevron.up")
            .frame(width: 30, height: 28)
        }
        .buttonStyle(.borderless)
        .disabled(selection == nil || selection == 0)

        Divider().frame(height: 14)

        Button(action: moveDown) {
          Image(systemName: "chevron.down")
            .frame(width: 30, height: 28)
        }
        .buttonStyle(.borderless)
        .disabled(selection == nil || selection == settings.workspaces.count - 1)

        Divider().frame(height: 14)

        Button(action: duplicateSelected) {
          Image(systemName: "doc.on.doc")
            .frame(width: 30, height: 28)
        }
        .buttonStyle(.borderless)
        .disabled(selection == nil)

        Spacer()
      }
      .contentShape(Rectangle())
      .onTapGesture {
        if editingIndex != nil { commitEdit() }
      }
      .background(footerBg)
    }
    .background(listBg)
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background {
      Color.clear
        .contentShape(Rectangle())
        .onTapGesture {
          if editingIndex != nil { commitEdit() }
          selection = nil
        }
    }
    .onAppear {
      settings.workspaces.removeAll { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }
    .sheet(
      isPresented: Binding(
        get: { configuringIndex != nil },
        set: { if !$0 { configuringIndex = nil } }
      )
    ) {
      if let index = configuringIndex, index < settings.workspaces.count {
        WorkspaceDetailView(
          settings: settings,
          workspaceIndex: index,
          onBack: { configuringIndex = nil }
        )
        .frame(minWidth: 550, minHeight: 400)
      }
    }
  }

  private func addRow() {
    if editingIndex != nil { commitEdit() }
    settings.workspaces.append(WorkspaceConfig())
    let newIndex = settings.workspaces.count - 1
    selection = newIndex
    beginEdit(index: newIndex)
  }

  private func duplicateSelected() {
    guard let index = selection, index < settings.workspaces.count else { return }
    if editingIndex != nil { commitEdit() }
    let original = settings.workspaces[index]
    var copy = WorkspaceConfig(
      name: "\(original.name) Copy",
      path: original.path,
      launchers: original.launchers.map {
        AppLauncher(label: $0.label, type: $0.type, appName: $0.appName, command: $0.command)
      }
    )
    // Ensure new UUIDs for the copy
    copy.id = UUID()
    settings.workspaces.insert(copy, at: index + 1)
    selection = index + 1
  }

  private func moveUp() {
    guard let index = selection, index > 0 else { return }
    if editingIndex != nil { commitEdit() }
    settings.workspaces.swapAt(index, index - 1)
    selection = index - 1
  }

  private func moveDown() {
    guard let index = selection, index < settings.workspaces.count - 1 else { return }
    if editingIndex != nil { commitEdit() }
    settings.workspaces.swapAt(index, index + 1)
    selection = index + 1
  }

  private func removeSelected() {
    guard let index = selection, index < settings.workspaces.count else { return }
    if editingIndex == index { editingIndex = nil }
    settings.workspaces.remove(at: index)
    if settings.workspaces.isEmpty {
      selection = nil
    } else {
      selection = min(index, settings.workspaces.count - 1)
    }
  }

  private func beginEdit(index: Int) {
    editText = settings.workspaces[index].name
    editingIndex = index
    selection = index
  }

  private func commitEdit() {
    guard let index = editingIndex, index < settings.workspaces.count else {
      editingIndex = nil
      return
    }
    let trimmed = editText.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty {
      settings.workspaces.remove(at: index)
      selection = nil
    } else {
      settings.workspaces[index].name = trimmed
    }
    editingIndex = nil
    editText = ""
    selection = nil
  }

  private func cancelEdit() {
    guard let index = editingIndex, index < settings.workspaces.count else {
      editingIndex = nil
      return
    }
    if settings.workspaces[index].name.isEmpty {
      settings.workspaces.remove(at: index)
      selection = nil
    }
    editingIndex = nil
    editText = ""
  }
}

// MARK: - Row

private struct SpaceNameRow: View {
  let name: String
  let launcherCount: Int
  let isSelected: Bool
  let isEditing: Bool
  @Binding var editText: String
  let onSingleClick: () -> Void
  let onCommit: () -> Void
  let onCancel: () -> Void
  let onConfigure: () -> Void

  @FocusState private var isFocused: Bool

  var body: some View {
    if isEditing {
      TextField("", text: $editText)
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        .focused($isFocused)
        .onSubmit { onCommit() }
        .onExitCommand { onCancel() }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .task {
          try? await Task.sleep(for: .milliseconds(50))
          isFocused = true
          try? await Task.sleep(for: .milliseconds(50))
          NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: nil)
        }
    } else {
      HStack {
        Text(name)
        Spacer()
        if launcherCount > 0 {
          Text("\(launcherCount) app\(launcherCount == 1 ? "" : "s")")
            .font(.caption)
            .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
        }
        Button {
          onConfigure()
        } label: {
          Image(systemName: "gearshape")
            .font(.caption)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(isSelected ? .white : .secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(isSelected ? Color.accentColor : Color.clear)
      .foregroundStyle(isSelected ? .white : .primary)
      .contentShape(Rectangle())
      .onTapGesture { onSingleClick() }
    }
  }
}
