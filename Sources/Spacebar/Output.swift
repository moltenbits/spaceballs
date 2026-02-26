import Cocoa
import SpacebarCore

extension ListCommand {
  func printText(
    spaces: [SpaceInfo], windowMap: [UInt64: [WindowInfo]],
    spaceNameStore: SpaceNameStoring
  ) {
    let displayGroups = Dictionary(grouping: spaces, by: \.displayUUID)

    for (displayUUID, displaySpaces) in displayGroups.sorted(by: { $0.key < $1.key }) {
      print("══════════════════════════════════════════════════════════════")
      print(" Display: \(displayUUID)")
      print("══════════════════════════════════════════════════════════════")

      for (index, space) in displaySpaces.enumerated() {
        let marker = space.isCurrent ? "  ← ACTIVE" : ""
        let customName = spaceNameStore.customName(forSpaceUUID: space.uuid)
        let nameLabel = customName.map { " \"\($0)\"" } ?? ""
        print("")
        print(
          "  Space \(index + 1)\(nameLabel) [\(space.type.description)] (ID: \(space.id))\(marker)")
        print("  ────────────────────────────────────────────────")

        let windows = windowMap[space.id] ?? []
        if windows.isEmpty {
          print("    (no windows)")
        } else {
          for window in windows {
            let title = window.name.map { " — \($0)" } ?? ""
            let sticky = window.isSticky ? " [all spaces]" : ""
            print("    [\(window.id)] \(window.ownerName)\(title)\(sticky)")
          }
        }
      }
      print("")
    }

    // Summary
    let allWindowIDs = Set(windowMap.values.flatMap { $0 }.map(\.id))
    print(
      "Summary: \(spaces.count) space(s) across \(displayGroups.count) display(s), \(allWindowIDs.count) window(s)"
    )

    if spaces.allSatisfy({ !$0.isCurrent }) {
      print("")
      print(
        "WARNING: No space reported as current. CGS connection may not be fully initialized."
      )
    }

    // Hint about permissions
    let windowsWithNames = windowMap.values.flatMap { $0 }.filter { $0.name != nil }.count
    let totalWindows = allWindowIDs.count
    if totalWindows > 0 && windowsWithNames == 0 {
      print("")
      print(
        "NOTE: No window titles visible. Grant Screen Recording permission to your"
      )
      print("terminal in System Settings → Privacy & Security → Screen Recording.")
    }
  }

  func printJSON(
    spaces: [SpaceInfo], windowMap: [UInt64: [WindowInfo]],
    spaceNameStore: SpaceNameStoring
  ) throws {
    let displayGroups = Dictionary(grouping: spaces, by: \.displayUUID)

    let output: [[String: Any]] =
      displayGroups
      .sorted(by: { $0.key < $1.key })
      .map { displayUUID, displaySpaces in
        [
          "displayId": displayUUID,
          "spaces": displaySpaces.map { space in
            var spaceDict: [String: Any] = [
              "id": space.id,
              "uuid": space.uuid,
              "type": space.type.description,
              "isCurrent": space.isCurrent,
              "windows": (windowMap[space.id] ?? []).map { window in
                var dict: [String: Any] = [
                  "id": window.id,
                  "app": window.ownerName,
                  "pid": window.pid,
                  "sticky": window.isSticky,
                  "bounds": [
                    "x": window.bounds.origin.x,
                    "y": window.bounds.origin.y,
                    "width": window.bounds.width,
                    "height": window.bounds.height,
                  ],
                ]
                if let name = window.name {
                  dict["title"] = name
                }
                return dict
              },
            ]
            if let customName = spaceNameStore.customName(forSpaceUUID: space.uuid) {
              spaceDict["name"] = customName
            }
            return spaceDict
          },
        ] as [String: Any]
      }

    let data = try JSONSerialization.data(
      withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
  }
}
