import Testing

@testable import SpaceballsCore

/// Pure matching logic for Mission Control window thumbnails.
/// `displayTitles[0]` is the source display (the one showing the window's
/// space); later arrays are other displays in search order.
@Suite("Window Thumbnail Matching")
struct WindowThumbnailMatchTests {

  @Test("An exact match is found wherever it appears")
  func exactMatchAnywhere() {
    let result = SpaceManager.matchWindowThumbnail(
      displayTitles: [["bash", "Inbox"], ["spaceballs – SpaceManager.swift"]],
      windowTitle: "spaceballs – SpaceManager.swift")
    #expect(result?.display == 1)
    #expect(result?.index == 0)
  }

  @Test("An exact match on a later display beats an earlier substring match")
  func exactBeatsEarlierSubstring() {
    // The regression: display 0 (destination) holds ONE window whose title
    // merely contains the search string; display 1 (source) holds the real
    // window with the exact title. The old per-display loop grabbed the
    // substring match and never reached the exact one.
    let result = SpaceManager.matchWindowThumbnail(
      displayTitles: [
        ["jamesdh — ~/Projects/moltenbits/spaceballs — iTerm2"],
        ["spaceballs"],
      ],
      windowTitle: "spaceballs")
    #expect(result?.display == 1)
    #expect(result?.index == 0)
  }

  @Test("With no exact match, a substring match unique to the source display wins")
  func sourceDisplaySubstringWins() {
    let result = SpaceManager.matchWindowThumbnail(
      displayTitles: [
        ["spaceballs – EjectPlanner.swift [modified]"],
        ["jamesdh — spaceballs — iTerm2", "spaceballs — notes"],
      ],
      windowTitle: "spaceballs – EjectPlanner.swift")
    #expect(result?.display == 0)
    #expect(result?.index == 0)
  }

  @Test("With no source-display match, a globally unique substring match wins")
  func globallyUniqueSubstringWins() {
    let result = SpaceManager.matchWindowThumbnail(
      displayTitles: [["bash", "Inbox"], ["Google", "spaceballs — notes"]],
      windowTitle: "spaceballs")
    #expect(result?.display == 1)
    #expect(result?.index == 1)
  }

  @Test("An ambiguous substring match resolves to nil")
  func ambiguousSubstringIsNil() {
    let result = SpaceManager.matchWindowThumbnail(
      displayTitles: [["bash"], ["spaceballs — one", "spaceballs — two"]],
      windowTitle: "spaceballs")
    #expect(result == nil)
  }

  @Test("Substring matching is case-insensitive")
  func substringIsCaseInsensitive() {
    let result = SpaceManager.matchWindowThumbnail(
      displayTitles: [["SpaceBalls — Notes"]],
      windowTitle: "spaceballs")
    #expect(result?.display == 0)
    #expect(result?.index == 0)
  }

  @Test("Duplicate exact titles resolve to the source display's thumbnail")
  func duplicateExactPrefersSourceDisplay() {
    let result = SpaceManager.matchWindowThumbnail(
      displayTitles: [["untitled", "bash"], ["untitled"]],
      windowTitle: "untitled")
    #expect(result?.display == 0)
    #expect(result?.index == 0)
  }

  @Test("Nil titles and no match resolve to nil")
  func noMatchIsNil() {
    let result = SpaceManager.matchWindowThumbnail(
      displayTitles: [[nil, "bash"], []],
      windowTitle: "spaceballs")
    #expect(result == nil)
  }
}

/// macOS 27 exposes each thumbnail's CGWindowID (`wid`); it identifies the
/// window outright and must win over any title heuristic.
@Suite("Window Thumbnail Matching by Window ID")
struct WindowThumbnailWindowIDMatchTests {
  typealias Thumb = SpaceManager.ThumbnailDescriptor

  @Test("A matching wid wins over an exact title match elsewhere")
  func widBeatsExactTitle() {
    let result = SpaceManager.matchWindowThumbnail(
      displays: [
        [Thumb(title: "Home", windowID: 204), Thumb(title: "Home", windowID: 205)],
        [Thumb(title: "Home", windowID: 207)],
      ],
      windowTitle: "Home", windowID: 207)
    #expect(result?.display == 1)
    #expect(result?.index == 0)
  }

  @Test("Duplicate titles on one display resolve by wid")
  func duplicateTitlesResolveByWID() {
    let result = SpaceManager.matchWindowThumbnail(
      displays: [[Thumb(title: "Home", windowID: 204), Thumb(title: "Home", windowID: 213)]],
      windowTitle: "Home", windowID: 213)
    #expect(result?.display == 0)
    #expect(result?.index == 1)
  }

  @Test("Without a wid on any thumbnail, the title heuristics apply")
  func fallsBackToTitleWhenNoWID() {
    let result = SpaceManager.matchWindowThumbnail(
      displays: [
        [Thumb(title: "bash", windowID: nil)],
        [Thumb(title: "spaceballs – SpaceManager.swift", windowID: nil)],
      ],
      windowTitle: "spaceballs – SpaceManager.swift", windowID: 291)
    #expect(result?.display == 1)
    #expect(result?.index == 0)
  }

  @Test("With no wid to search for, the title heuristics apply")
  func fallsBackToTitleWhenNoWindowID() {
    let result = SpaceManager.matchWindowThumbnail(
      displays: [[Thumb(title: "spaceballs — notes", windowID: 12)]],
      windowTitle: "spaceballs", windowID: nil)
    #expect(result?.display == 0)
    #expect(result?.index == 0)
  }

  @Test("A wid that matches nothing still falls back to an unambiguous title")
  func unknownWIDFallsBackToTitle() {
    let result = SpaceManager.matchWindowThumbnail(
      displays: [[Thumb(title: "Inbox", windowID: 1), Thumb(title: "spaceballs", windowID: 2)]],
      windowTitle: "spaceballs", windowID: 999)
    #expect(result?.display == 0)
    #expect(result?.index == 1)
  }

  @Test("A wid that matches nothing and an ambiguous title resolve to nil")
  func unknownWIDAmbiguousTitleIsNil() {
    let result = SpaceManager.matchWindowThumbnail(
      displays: [
        [Thumb(title: "a spaceballs", windowID: 1), Thumb(title: "b spaceballs", windowID: 2)]
      ],
      windowTitle: "spaceballs", windowID: 999)
    #expect(result == nil)
  }
}
