import ApplicationServices

// MARK: - Private Accessibility Function
//
// Maps an AXUIElement (window) back to its CGWindowID.
// Lives in ApplicationServices/HIServices. Used by yabai, AltTab, Amethyst
// since ~macOS 10.9 — stable across all macOS versions through Sequoia.

/// Returns the CGWindowID for an AXUIElement representing a window.
///
/// - Parameters:
///   - element: An AXUIElement for a window (from kAXWindowsAttribute)
///   - windowID: On return, the CGWindowID for the element
/// - Returns: An AXError code (.success if the mapping succeeded)
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError
