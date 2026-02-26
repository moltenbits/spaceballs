import CoreGraphics

// MARK: - Private CoreGraphics Server Types

public typealias CGSConnectionID = Int32

// MARK: - Space Selector Masks
//
// These are passed to CGSCopySpacesForWindows to control which spaces are queried.
// Values determined empirically from reverse-engineering (used by yabai, Amethyst, etc.)

public enum CGSSpaceMask: Int32 {
  case current = 5
  case other = 6
  case all = 7
}

// MARK: - Space Types (from CGSCopyManagedDisplaySpaces output)

public enum CGSSpaceType: Int {
  case desktop = 0  // Normal user desktop
  case fullscreen = 4  // Fullscreen app space

  public var description: String {
    switch self {
    case .desktop: return "Desktop"
    case .fullscreen: return "Fullscreen"
    }
  }
}

// MARK: - Private CGS Functions
//
// These symbols live in the SkyLight private framework, which is loaded
// transitively through CoreGraphics/AppKit. @_silgen_name resolves them
// at link time from the dyld shared cache.

/// Returns the default CGS connection for the current process.
@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

/// Returns an array of dictionaries describing each display and its spaces.
///
/// Each element has the shape:
/// ```
/// {
///   "Display Identifier": String,       // display UUID
///   "Current Space": {                   // currently active space
///     "ManagedSpaceID": Int,
///     "id64": Int,
///     "type": Int,                       // 0 = desktop, 4 = fullscreen
///     "uuid": String
///   },
///   "Spaces": [{ ... same keys ... }]   // all spaces on this display
/// }
/// ```
@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray

/// Returns the space IDs that the given windows belong to.
///
/// - Parameters:
///   - cid: CGS connection ID
///   - mask: Space selector (5 = current, 6 = other, 7 = all)
///   - windowIDs: CFArray of window ID numbers
/// - Returns: CFArray of space ID numbers
@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: Int32, _ windowIDs: CFArray) -> CFArray

/// Sends a notification to the Dock via the private CoreDock framework.
///
/// Used to trigger Mission Control (`"com.apple.expose.awake"`).
/// Part of CoreServices, loaded transitively through AppKit.
@_silgen_name("CoreDockSendNotification")
func CoreDockSendNotification(_ notification: CFString)
