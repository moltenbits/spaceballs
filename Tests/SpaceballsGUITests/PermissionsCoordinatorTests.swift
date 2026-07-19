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

  @Test("Prompts ONLY Accessibility when both are missing")
  func promptsOnlyAccessibilityWhenBothMissing() {
    // macOS shows the Screen Recording consent dialog at most once per process,
    // and a request made while another TCC dialog is up is silently dropped —
    // firing both at once wastes the one SR prompt and forces a relaunch.
    let h = Harness()
    let coordinator = h.makeCoordinator()

    coordinator.checkAndPrompt()

    #expect(h.accessibilityPrompts == 1)
    #expect(h.screenRecordingPrompts == 0)
  }

  @Test("Prompts Screen Recording once Accessibility is granted, no relaunch needed")
  func screenRecordingFollowsAccessibilityGrant() {
    let h = Harness()
    let coordinator = h.makeCoordinator()

    coordinator.checkAndPrompt()  // AX prompted, SR held back
    h.accessibilityTrusted = true  // user grants AX
    coordinator.checkAndPrompt()  // re-check (keyInterceptorReady / activation)

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

  @Test("Grant detection fires exactly once after SR was seen missing then granted")
  func screenRecordingGrantDetectedOnce() {
    let h = Harness()
    h.accessibilityTrusted = true
    let coordinator = h.makeCoordinator()

    coordinator.checkAndPrompt()  // SR missing, observed + prompted
    #expect(coordinator.didScreenRecordingJustBecomeGranted() == false)  // still missing

    h.screenRecordingGranted = true  // user toggles it on in System Settings
    #expect(coordinator.didScreenRecordingJustBecomeGranted() == true)  // one-shot
    #expect(coordinator.didScreenRecordingJustBecomeGranted() == false)  // consumed
  }

  @Test("Grant detection never fires when SR was granted from the start")
  func grantDetectionSilentWhenAlwaysGranted() {
    let h = Harness()
    h.accessibilityTrusted = true
    h.screenRecordingGranted = true
    let coordinator = h.makeCoordinator()

    coordinator.checkAndPrompt()
    #expect(coordinator.didScreenRecordingJustBecomeGranted() == false)
  }

  @Test("Grant detection observes SR missing even while Accessibility gates the prompt")
  func grantDetectionObservesWhileGatedOnAccessibility() {
    // Both missing: SR isn't prompted yet (sequenced behind AX), but the
    // missing state is still recorded so a later grant triggers the restart.
    let h = Harness()
    let coordinator = h.makeCoordinator()

    coordinator.checkAndPrompt()  // AX prompted; SR observed missing, not prompted
    h.screenRecordingGranted = true
    #expect(coordinator.didScreenRecordingJustBecomeGranted() == true)
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
    h.accessibilityTrusted = true  // isolate the SR debounce
    let coordinator = h.makeCoordinator(promptInterval: 60)

    coordinator.checkAndPrompt()
    h.advance(by: 5)
    coordinator.checkAndPrompt()
    h.advance(by: 30)
    coordinator.checkAndPrompt()

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
    #expect(h.screenRecordingPrompts == 0)  // still sequenced behind AX
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
