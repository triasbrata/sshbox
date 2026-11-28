// What xdotool is on Linux, for the macOS several-windows e2e: an app's windows
// listed with their frames, real mouse and key events posted to the HID system,
// as a hand's are. Compiled once by tools/e2e_desktop.sh and run by
// integration_test/mac_desk.dart. Frames are in points, origin at the top left
// of the main screen, as CGWindowList and CGEvent both give them.
//
//   mwtool windows PID [all]      one line a window: "number x y w h"
//   mwtool screen                  "width height" of the main screen
//   mwtool click NUMBER X Y VIEWH [BUTTON]
//                                  a click at X, Y in the window's own view, whose
//                                  height is VIEWH (the title bar sits above it)
//   mwtool key CHORD               cmd+shift+n, ctrl+n, cmd+equal, Return...

import Cocoa
import CoreGraphics

func listed(pid: pid_t, all: Bool) -> [(number: Int, rect: CGRect)] {
  let options: CGWindowListOption = all ? [.optionAll] : [.optionOnScreenOnly]
  let list =
    CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
  var found: [(number: Int, rect: CGRect)] = []
  for window in list {
    guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
      (window[kCGWindowLayer as String] as? Int) == 0,
      let number = window[kCGWindowNumber as String] as? Int,
      let dictionary = window[kCGWindowBounds as String] as? NSDictionary,
      let rect = CGRect(dictionaryRepresentation: dictionary)
    else { continue }
    // The helper windows an app keeps are small or empty; a window is wider.
    if rect.width < 100 || rect.height < 100 { continue }
    found.append((number, rect))
  }
  return found.sorted { $0.number < $1.number }
}

let args = CommandLine.arguments
guard args.count >= 2 else {
  FileHandle.standardError.write("usage: mwtool windows|screen|click|key ...\n".data(using: .utf8)!)
  exit(2)
}

func post(_ type: CGEventType, at: CGPoint, button: CGMouseButton) {
  let event = CGEvent(
    mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: button)!
  event.post(tap: .cghidEventTap)
}

switch args[1] {
case "windows":
  let pid = pid_t(args[2])!
  for window in listed(pid: pid, all: args.count > 3) {
    print(
      "\(window.number) \(Int(window.rect.minX.rounded())) \(Int(window.rect.minY.rounded())) "
        + "\(Int(window.rect.width.rounded())) \(Int(window.rect.height.rounded()))")
  }
case "dump":
  // Everything the window server says of this process's windows.
  let pid = pid_t(args[2])!
  let list =
    CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
  for window in list where (window[kCGWindowOwnerPID as String] as? pid_t) == pid {
    let number = window[kCGWindowNumber as String] ?? "?"
    let layer = window[kCGWindowLayer as String] ?? "?"
    let alpha = window[kCGWindowAlpha as String] ?? "?"
    let onscreen = window[kCGWindowIsOnscreen as String] ?? "no"
    let bounds = window[kCGWindowBounds as String] ?? "?"
    print("#\(number) layer \(layer) alpha \(alpha) onscreen \(onscreen) \(bounds)")
  }
case "screen":
  let frame = NSScreen.main?.frame ?? .zero
  print("\(Int(frame.width)) \(Int(frame.height))")
case "click":
  let number = Int(args[2])!
  let x = Double(args[3])!
  let y = Double(args[4])!
  let viewHeight = Double(args[5])!
  let right = args.count > 6 && args[6] == "3"
  // The window by its number, on screen or not.
  let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
  guard
    let window = all.first(where: { ($0[kCGWindowNumber as String] as? Int) == number }),
    let dictionary = window[kCGWindowBounds as String] as? NSDictionary,
    let bounds = CGRect(dictionaryRepresentation: dictionary)
  else {
    FileHandle.standardError.write("no window \(number)\n".data(using: .utf8)!)
    exit(1)
  }
  let at = CGPoint(x: bounds.minX + x, y: bounds.maxY - viewHeight + y)
  let (down, up, drag, button): (CGEventType, CGEventType, CGEventType, CGMouseButton) =
    right
    ? (.rightMouseDown, .rightMouseUp, .rightMouseDragged, .right)
    : (.leftMouseDown, .leftMouseUp, .leftMouseDragged, .left)
  _ = drag
  post(.mouseMoved, at: at, button: button)
  usleep(200_000)
  post(down, at: at, button: button)
  usleep(60_000)
  post(up, at: at, button: button)
  usleep(50_000)
  print("clicked \(Int(at.x)),\(Int(at.y)) in window \(number) (\(bounds))")
case "key":
  let parts = args[2].split(separator: "+").map { String($0).lowercased() }
  // Each modifier with the bit naming its left key, as a keyboard sets it:
  // Flutter tells a modifier's press from its release by that bit.
  let modifiers: [String: (CGKeyCode, UInt64)] = [
    "cmd": (55, CGEventFlags.maskCommand.rawValue | 0x8),
    "shift": (56, CGEventFlags.maskShift.rawValue | 0x2),
    "ctrl": (59, CGEventFlags.maskControl.rawValue | 0x1),
    "alt": (58, CGEventFlags.maskAlternate.rawValue | 0x20),
  ]
  let keys: [String: CGKeyCode] = [
    "a": 0, "c": 8, "n": 45, "v": 9, "w": 13, "equal": 24, "minus": 27,
    "return": 36, "tab": 48, "escape": 53,
  ]
  let source = CGEventSource(stateID: .hidSystemState)
  var held: [(CGKeyCode, UInt64)] = []
  var flags: UInt64 = 0
  var main: CGKeyCode? = nil
  for part in parts {
    if let modifier = modifiers[part] {
      held.append(modifier)
      flags |= modifier.1
      let event = CGEvent(keyboardEventSource: source, virtualKey: modifier.0, keyDown: true)!
      event.flags = CGEventFlags(rawValue: flags)
      event.post(tap: .cghidEventTap)
      usleep(80_000)
    } else if let code = keys[part] {
      main = code
    } else {
      FileHandle.standardError.write("no key called \(part)\n".data(using: .utf8)!)
      exit(1)
    }
  }
  if let code = main {
    for down in [true, false] {
      let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)!
      event.flags = CGEventFlags(rawValue: flags)
      event.post(tap: .cghidEventTap)
      usleep(60_000)
    }
  }
  for modifier in held.reversed() {
    flags &= ~modifier.1
    let event = CGEvent(keyboardEventSource: source, virtualKey: modifier.0, keyDown: false)!
    event.flags = CGEventFlags(rawValue: flags)
    event.post(tap: .cghidEventTap)
    usleep(80_000)
  }
  print("key \(args[2])")
default:
  FileHandle.standardError.write("no command \(args[1])\n".data(using: .utf8)!)
  exit(2)
}
