import SpacebarGUILib
import SwiftUI

struct SpacesPane: View {
  @ObservedObject var settings: AppSettings
  @State private var selection: Int? = nil
  @State private var editingIndex: Int? = nil
  @State private var editText: String = ""

  private let listBg = Color(white: 0.97)
  private let footerBg = Color(white: 0.935)

  var body: some View {
    VStack(spacing: 0) {
      // Description
      Text(
        "Define the default names for your Spaces. When Spacebar sees unnamed spaces, it will assign these names in order."
      )
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)

      // Rows
      ForEach(0..<settings.customSpaceNames.count, id: \.self) { index in
        Rectangle()
          .fill(Color.primary.opacity(0.05))
          .frame(height: 1)
        SpaceNameRow(
          name: settings.customSpaceNames[index],
          isSelected: selection == index,
          isEditing: editingIndex == index,
          editText: $editText,
          onTap: {
            if editingIndex != nil && editingIndex != index {
              commitEdit()
            }
            if selection == index && editingIndex != index {
              beginEdit(index: index)
            } else {
              selection = index
            }
          },
          onCommit: { commitEdit() },
          onCancel: { cancelEdit() }
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
        .disabled(selection == nil || selection == settings.customSpaceNames.count - 1)

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
    .onAppear {
      settings.customSpaceNames.removeAll { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
  }

  private func addRow() {
    if editingIndex != nil { commitEdit() }
    settings.customSpaceNames.append("")
    let newIndex = settings.customSpaceNames.count - 1
    selection = newIndex
    beginEdit(index: newIndex)
  }

  private func moveUp() {
    guard let index = selection, index > 0 else { return }
    if editingIndex != nil { commitEdit() }
    settings.customSpaceNames.swapAt(index, index - 1)
    selection = index - 1
  }

  private func moveDown() {
    guard let index = selection, index < settings.customSpaceNames.count - 1 else { return }
    if editingIndex != nil { commitEdit() }
    settings.customSpaceNames.swapAt(index, index + 1)
    selection = index + 1
  }

  private func removeSelected() {
    guard let index = selection, index < settings.customSpaceNames.count else { return }
    if editingIndex == index { editingIndex = nil }
    settings.customSpaceNames.remove(at: index)
    if settings.customSpaceNames.isEmpty {
      selection = nil
    } else {
      selection = min(index, settings.customSpaceNames.count - 1)
    }
  }

  private func beginEdit(index: Int) {
    editText = settings.customSpaceNames[index]
    editingIndex = index
    selection = index
  }

  private func commitEdit() {
    guard let index = editingIndex, index < settings.customSpaceNames.count else {
      editingIndex = nil
      return
    }
    let trimmed = editText.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty {
      settings.customSpaceNames.remove(at: index)
      selection = nil
    } else {
      settings.customSpaceNames[index] = trimmed
    }
    editingIndex = nil
    editText = ""
    selection = nil
  }

  private func cancelEdit() {
    guard let index = editingIndex, index < settings.customSpaceNames.count else {
      editingIndex = nil
      return
    }
    if settings.customSpaceNames[index].isEmpty {
      settings.customSpaceNames.remove(at: index)
      selection = nil
    }
    editingIndex = nil
    editText = ""
  }
}

// MARK: - Row

private struct SpaceNameRow: View {
  let name: String
  let isSelected: Bool
  let isEditing: Bool
  @Binding var editText: String
  let onTap: () -> Void
  let onCommit: () -> Void
  let onCancel: () -> Void

  @FocusState private var isFocused: Bool

  var body: some View {
    Group {
      if isEditing {
        TextField("", text: $editText)
          .textFieldStyle(.roundedBorder)
          .labelsHidden()
          .focused($isFocused)
          .onSubmit { onCommit() }
          .onExitCommand { onCancel() }
          .onChange(of: isFocused) { _, focused in
            if !focused { onCommit() }
          }
          .onAppear { isFocused = true }
      } else {
        Text(name)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, isEditing ? 6 : 12)
    .padding(.vertical, isEditing ? 4 : 8)
    .background(isSelected && !isEditing ? Color.accentColor : Color.clear)
    .foregroundStyle(isSelected && !isEditing ? .white : .primary)
    .contentShape(Rectangle())
    .onTapGesture { onTap() }
  }
}
