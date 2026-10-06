import AppKit
import ApplicationServices
let pid = pid_t(CommandLine.arguments[1])!
let action = CommandLine.arguments[2]
if action == "quit" {
 print(NSRunningApplication(processIdentifier: pid)?.terminate() == true ? "accepted" : "rejected")
} else {
 guard AXIsProcessTrusted() else { print("accessibility-unavailable"); exit(2) }
 let app = AXUIElementCreateApplication(pid)
 var value: CFTypeRef?
 guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
       let windows = value as? [AXUIElement], let window = windows.first else { exit(3) }
 if action == "close" {
  var button: CFTypeRef?
  guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button) == .success, let button else { exit(4) }
  let result = AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
  print(result.rawValue);exit(result == .success ? 0 : 5)
 }
}
