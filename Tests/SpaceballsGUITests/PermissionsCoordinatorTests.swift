import Foundation
import Testing

@testable import SpaceballsGUILib

/// Test harness: tracks prompt invocations and lets tests control permission
/// state and the clock.
private final class Harness {
  var accessibilityTrusted = false
  var screenRecordingGranted = false
  var accessibilityPrompts = 0
  var screenRecordingPrompts = 0
  var now = Date(timeIntervalSinceReferenceDate: 0)

  func makeCoordinator(promptInterval: TimeInterval = 60) -> PermissionsCoordinator {
    PermissionsCoordinator(
      promptInterval: promptInterval,
      isAccessibilityTrusted: { self.accessibilityTrusted },
      promptAccessibility: { self.accessibilityPrompts += 1 },
      hasScreenRecording: { self.screenRecordingGranted },
      promptScreenRecording: { self.screenRecordingPrompts += 1 },
      now: { self.now }
    )
  }

  func advance(by seconds: TimeInterval) {
    now = now.addingTimeInterval(seconds)
  }
}

@Suite("Permissions Coordinator")
struct PermissionsCoordinatorTests {

  @Test("Prompts for both permissions when both are missing")
  func promptsBothWhenMissing() {
    let h = Harness()
    let coordinator = h.makeCoordinator()

    coordinator.checkAndPrompt()

    #expect(h.accessibilityPrompts == 1)
    #expect(h.screenRecordingPrompts == 1)
  }

  @Test("Prompts for nothing when both are granted")
  func silentWhenGranted() {
    let h = Harness()
    h.accessibilityTrusted = true
    h.screenRecordingGranted = true
    let coordinator = h.makeCoordinator()

    coordinator.checkAndPrompt()

    #expect(h.accessibilityPrompts == 0)
    #expect(h.screenRecordingPrompts == 0)
  }

  @Test("Screen Recording is prompted even when Accessibility is missing")
  func screenRecordingNotGatedOnAccessibility() {
    // Regression guard: the old flow requested Screen Recording only after the
    // event tap existed (i.e. after Accessibility was granted), so a machine
    // missing both never registered in the Screen Recording pane.
    let h = Harness()
    h.accessibilityTrusted = false
    h.screenRecordingGranted = false
    let coordinator = h.makeCoordinator()

    coordinator.checkAndPrompt()

    #expect(h.screenRecordingPrompts == 1)
  }

  @Test("Prompts only for the permission that is missing")
  func promptsOnlyMissingPermission() {
    let h = Harness()
    h.accessibilityTrusted = true
    let coordinator = h.makeCoordinator()

    coordinator.checkAndPrompt()

    #expect(h.accessibilityPrompts == 0)
    #expect(h.screenRecordingPrompts == 1)
  }

  @Test("Repeated checks within the prompt interval do not re-prompt")
  func debouncesWithinInterval() {
    let h = Harness()
    let coordinator = h.makeCoordinator(promptInterval: 60)

    coordinator.checkAndPrompt()
    h.advance(by: 5)
    coordinator.checkAndPrompt()
    h.advance(by: 30)
    coordinator.checkAndPrompt()

    #expect(h.accessibilityPrompts == 1)
    #expect(h.screenRecordingPrompts == 1)
  }

  @Test("Re-prompts after the interval elapses if still missing")
  func repromptsAfterInterval() {
    let h = Harness()
    let coordinator = h.makeCoordinator(promptInterval: 60)

    coordinator.checkAndPrompt()
    h.advance(by: 61)
    coordinator.checkAndPrompt()

    #expect(h.accessibilityPrompts == 2)
    #expect(h.screenRecordingPrompts == 2)
  }

  @Test("Prompts again immediately when a permission is lost after being granted")
  func promptsOnRevocation() {
    let h = Harness()
    h.accessibilityTrusted = true
    h.screenRecordingGranted = true
    let coordinator = h.makeCoordinator(promptInterval: 60)

    coordinator.checkAndPrompt()  // granted — no prompts, no debounce started
    h.advance(by: 5)
    h.accessibilityTrusted = false  // e.g. TCC reset after re-signing
    coordinator.checkAndPrompt()

    #expect(h.accessibilityPrompts == 1)
    #expect(h.screenRecordingPrompts == 0)
  }
}
