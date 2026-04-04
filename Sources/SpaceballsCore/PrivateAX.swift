import ApplicationServices

// MARK: - Private Accessibility Functions
//
// These symbols live in ApplicationServices/HIServices. Used by AltTab, yabai,
// and Amethyst. Stable across all macOS versions through Sequoia.

/// Returns the CGWindowID for an AXUIElement representing a window.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

/// Creates an AXUIElement from a raw "remote token" — a 20-byte data blob:
///   bytes  0..3:  pid (Int32)
///   bytes  4..7:  zero (Int32)
///   bytes  8..11: 0x636f636f ("coco" — marks this as a Cocoa element)
///   bytes 12..19: AXUIElementID (UInt64, the element index within the process)
///
/// This allows constructing AXUIElement handles for windows that
/// `kAXWindowsAttribute` doesn't return — notably windows on other Spaces.
/// AltTab discovered this workaround in Feb 2025 (issue #1324).
@_silgen_name("_AXUIElementCreateWithRemoteToken")
@discardableResult
func _AXUIElementCreateWithRemoteToken(_ data: CFData) -> Unmanaged<AXUIElement>?
