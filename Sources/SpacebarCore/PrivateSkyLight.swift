import ApplicationServices

// MARK: - Deprecated Carbon API (unavailable in Swift, still functional)
//
// GetProcessForPID was deprecated in macOS 10.9 and marked unavailable
// in Swift, but the symbol is still present and used by yabai/AltTab
// to obtain ProcessSerialNumbers for the SkyLight APIs below.

@_silgen_name("GetProcessForPID")
@discardableResult
func GetProcessForPID(
  _ pid: pid_t,
  _ psn: UnsafeMutablePointer<ProcessSerialNumber>
) -> OSStatus

// MARK: - Private SkyLight Process/Window APIs
//
// These symbols live in the SkyLight private framework. Used by yabai and
// AltTab for focusing specific windows across Spaces. Unlike
// NSRunningApplication.activate(), these target a specific CGWindowID
// and trigger macOS's space-switch animation automatically.

/// Brings a process to the foreground, targeting a specific window.
///
/// When called with `mode = 0x200` (user-generated) and a valid window ID,
/// macOS will switch to the Space containing that window (if the system
/// preference "When switching to an application, switch to a Space with
/// open windows" is enabled — on by default).
///
/// - Parameters:
///   - psn: ProcessSerialNumber of the target app (from `GetProcessForPID`)
///   - wid: The CGWindowID to target
///   - mode: Activation mode — 0x200 (user-generated) for standard focus
@_silgen_name("_SLPSSetFrontProcessWithOptions")
@discardableResult
func _SLPSSetFrontProcessWithOptions(
  _ psn: UnsafeMutablePointer<ProcessSerialNumber>,
  _ wid: CGWindowID,
  _ mode: UInt32
) -> CGError

/// Posts a synthetic WindowServer event record to a process.
///
/// Used to send key-window-changed events, making a specific window
/// the key window of its owning app. Called twice with event types
/// 0x01 (key down) and 0x02 (key up).
///
/// - Parameters:
///   - psn: ProcessSerialNumber of the target app
///   - bytes: A 0xf8-byte event record (see `makeKeyWindow` for layout)
@_silgen_name("SLPSPostEventRecordTo")
@discardableResult
func SLPSPostEventRecordTo(
  _ psn: UnsafeMutablePointer<ProcessSerialNumber>,
  _ bytes: UnsafeMutablePointer<UInt8>
) -> CGError
