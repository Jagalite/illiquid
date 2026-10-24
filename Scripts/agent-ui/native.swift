// One request per process. Build: swiftc native.swift -o native
// No permission prompts, application launches, implicit activation, or AX fallback.
// Points/AX bounds use Quartz global logical points (top-left of primary display).
// target.window_id is a numeric CGWindowID. Ephemeral ids are tree-fingerprinted;
// re-inspect after layout/tree changes. expected_identity pins a previous identity
// using executable_path and process_start_identity. Input success means dispatched,
// never handled/presented. SIGINT/SIGTERM and all error exits release held input.
// SIGKILL cannot run cleanup: callers must allow a SIGTERM grace period and pass
// timeout below their own deadline. timeout defaults to 5s (0.1...30), max_depth
// to 20 (1...64), max_elements to 2000 (1...10000). Truncated trees cannot act.
// Scroll uses delta_x/delta_y and unit:"pixel"|"line". AX type replaces AXValue.
// menu/focus/window are AX-only; other unsupported mode/action pairs fail closed.
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

typealias Object = [String: Any]
let null = NSNull()

struct Failure: Error {
    let status: String
    let message: String
    var data: Object = [:]
    init(_ status: String = "error", _ message: String, _ data: Object = [:]) {
        self.status = status; self.message = message; self.data = data
    }
}

func string(_ object: Object, _ key: String, required: Bool = false) throws -> String? {
    guard let value = object[key] else {
        if required { throw Failure("missing \(key)") }
        return nil
    }
    guard let value = value as? String, !value.isEmpty else { throw Failure("\(key) must be a nonempty string") }
    return value
}

extension Failure {
    init(_ message: String) { self.init("error", message) }
}

func number(_ object: Object, _ key: String, default fallback: Double? = nil,
            range: ClosedRange<Double>? = nil) throws -> Double {
    guard let raw = object[key] else {
        guard let fallback else { throw Failure("missing \(key)") }
        return fallback
    }
    guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
          n.doubleValue.isFinite, range?.contains(n.doubleValue) ?? true else {
        throw Failure("\(key) must be a finite number\(range.map { " in \($0)" } ?? "")")
    }
    return n.doubleValue
}

func integer(_ object: Object, _ key: String, default fallback: Int? = nil,
             range: ClosedRange<Int> = 0...Int(Int32.max)) throws -> Int {
    let value = try number(object, key, default: fallback.map(Double.init),
                           range: Double(range.lowerBound)...Double(range.upperBound))
    guard value.rounded() == value else { throw Failure("\(key) must be an integer") }
    return Int(value)
}

func object(_ source: Object, _ key: String, required: Bool = false) throws -> Object? {
    guard let value = source[key] else {
        if required { throw Failure("missing \(key)") }
        return nil
    }
    guard let value = value as? Object else { throw Failure("\(key) must be an object") }
    return value
}

func point(_ object: Object) throws -> CGPoint {
    CGPoint(x: try number(object, "x", range: -1_000_000...1_000_000),
            y: try number(object, "y", range: -1_000_000...1_000_000))
}

func frame(_ object: Object) throws -> CGRect {
    CGRect(origin: try point(object), size: CGSize(
        width: try number(object, "width", range: 1...100_000),
        height: try number(object, "height", range: 1...100_000)))
}

func jsonRect(_ rect: CGRect?) -> Any {
    guard let r = rect, !r.isNull, !r.isInfinite,
          [r.minX, r.minY, r.width, r.height].allSatisfy({ $0.isFinite }) else { return null }
    return ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height]
}

struct Budget {
    let deadline: UInt64
    init(seconds: Double) { deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1e9) }
    var remaining: Double { max(0, Double(deadline) / 1e9 - Double(DispatchTime.now().uptimeNanoseconds) / 1e9) }
    func check() throws { if remaining <= 0 { throw Failure("timed-out", "native request deadline exceeded") } }
}

struct Identity {
    let pid: pid_t
    let alive: Bool
    let executable: String?
    let start: String?
    let bundle: String?
    var json: Object {
        ["pid": Int(pid), "alive": alive, "executable_path": executable as Any? ?? null,
         "process_start_identity": start as Any? ?? null, "bundle_id": bundle as Any? ?? null]
    }
    static func read(_ pid: pid_t) -> Identity {
        var info = proc_bsdinfo()
        let bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        let available = bytes == MemoryLayout<proc_bsdinfo>.size
        let alive = available ? info.pbi_status != UInt32(SZOMB) : (kill(pid, 0) == 0 || errno == EPERM)
        // PROC_PIDPATHINFO_MAXSIZE is an unimportable macro on recent Swift SDKs.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = length > 0 ? String(cString: buffer) : nil
        let start = available ? "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)" : nil
        return Identity(pid: pid, alive: alive, executable: path, start: start,
                        bundle: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
    }
    func validate(_ expected: Object?) throws {
        guard alive else { throw Failure("target-lost", "PID \(pid) is not alive", ["identity": json]) }
        guard let expected else { return }
        guard !expected.isEmpty, Set(expected.keys).isSubset(of: ["pid", "executable_path", "process_start_identity", "bundle_id"]) else {
            throw Failure("expected_identity contains no constraints or unknown fields")
        }
        for key in expected.keys {
            if key == "pid" {
                guard try integer(expected, key, range: 1...Int(Int32.max)) == Int(pid) else {
                    throw Failure("target-lost", "identity mismatch: pid", ["identity": json])
                }
            } else {
                let value = try string(expected, key, required: true)!
                guard let actual = json[key] as? String, actual == value else {
                    throw Failure("target-lost", "identity mismatch: \(key)", ["identity": json])
                }
            }
        }
    }
    func revalidate() throws {
        guard let start, let executable else { throw Failure("unsupported", "cannot pin process start and executable identity") }
        try Identity.read(pid).validate(["process_start_identity": start, "executable_path": executable])
    }
}

struct WindowInfo {
    let id: Int
    let bounds: CGRect
    let title: String?
    let onScreen: Bool
    let layer: Int
    var json: Object {
        ["window_id": id, "bounds": jsonRect(bounds), "title": title as Any? ?? null,
         "visible": onScreen, "layer": layer]
    }
}

func windows(_ pid: pid_t) -> [WindowInfo] {
    guard let entries = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [Object] else { return [] }
    return entries.compactMap { entry in
        guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              let id = entry[kCGWindowNumber as String] as? Int,
              let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
        return WindowInfo(id: id, bounds: rect, title: entry[kCGWindowName as String] as? String,
                          onScreen: (entry[kCGWindowIsOnscreen as String] as? Bool) ?? false,
                          layer: (entry[kCGWindowLayer as String] as? Int) ?? 0)
    }
}

func requireAX() throws {
    guard AXIsProcessTrusted() else { throw Failure("permission-required", "Accessibility permission is required; helper never prompts") }
}

func axAttribute(_ element: AXUIElement, _ name: String, _ budget: Budget) throws -> CFTypeRef? {
    try budget.check()
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    switch error {
    case .success: return value
    case .attributeUnsupported, .noValue, .notImplemented: return nil
    case .invalidUIElement: throw Failure("target-lost", "Accessibility element disappeared")
    case .apiDisabled: throw Failure("permission-required", "Accessibility API is disabled")
    case .cannotComplete: throw Failure("timed-out", "Accessibility messaging could not complete")
    default: throw Failure("AX attribute \(name) failed: \(error.rawValue)")
    }
}

func axElements(_ element: AXUIElement, _ name: String, limit: Int, _ budget: Budget) throws -> ([AXUIElement], Bool) {
    try budget.check()
    var count: CFIndex = 0
    let error = AXUIElementGetAttributeValueCount(element, name as CFString, &count)
    if error == .attributeUnsupported || error == .noValue || error == .notImplemented { return ([], false) }
    guard error == .success else { throw Failure(error == .cannotComplete ? "timed-out" : "error", "AX count \(name) failed: \(error.rawValue)") }
    guard count > 0 else { return ([], false) }
    let take = min(count, max(0, limit))
    guard take > 0 else { return ([], true) }
    try budget.check()
    var values: CFArray?
    let read = AXUIElementCopyAttributeValues(element, name as CFString, 0, take, &values)
    guard read == .success, let array = values as? [AXUIElement] else {
        throw Failure(read == .cannotComplete ? "timed-out" : "error", "AX children read failed: \(read.rawValue)")
    }
    return (array, take < count)
}

func axRect(_ element: AXUIElement, _ budget: Budget) throws -> CGRect? {
    guard let p = try axAttribute(element, kAXPositionAttribute, budget), CFGetTypeID(p) == AXValueGetTypeID(),
          let s = try axAttribute(element, kAXSizeAttribute, budget), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var origin = CGPoint.zero; var size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(s as! AXValue, .cgSize, &size),
          [origin.x, origin.y, size.width, size.height].allSatisfy({ $0.isFinite }), size.width >= 0, size.height >= 0 else { return nil }
    return CGRect(origin: origin, size: size)
}

func safeValue(_ value: CFTypeRef?) -> Any {
    guard let value else { return null }
    if let s = value as? String { return String(s.prefix(4096)) }
    if let n = value as? NSNumber, n.doubleValue.isFinite { return n }
    return null
}

struct Node {
    let ax: AXUIElement?
    let path: String
    let identifier: String?
    let role: String?
    let label: String?
    let value: Any
    let enabled: Bool?
    let focused: Bool?
    let visible: Bool?
    let bounds: CGRect?
    let windowID: Int?
    let isWindow: Bool
    func json(_ fingerprint: String) -> Object {
        ["id": "ax:\(fingerprint):\(path)", "identifier": identifier as Any? ?? null,
         "role": role as Any? ?? null, "label": label as Any? ?? null, "value": value,
         "enabled": enabled as Any? ?? null, "focused": focused as Any? ?? null,
         "visible": visible as Any? ?? null, "bounds": jsonRect(bounds),
         "window_id": windowID as Any? ?? null]
    }
}

func treeFingerprint(_ nodes: [Node], identity: Identity) throws -> String {
    let content: Object = ["identity": identity.json, "nodes": nodes.map {
        ["path": $0.path, "identifier": $0.identifier as Any? ?? null,
         "role": $0.role as Any? ?? null, "label": $0.label as Any? ?? null,
         "bounds": jsonRect($0.bounds), "window_id": $0.windowID as Any? ?? null] as Object
    }]
    return SHA256.hash(data: try JSONSerialization.data(withJSONObject: content, options: [.sortedKeys]))
        .map { String(format: "%02x", $0) }.joined()
}

struct Selector {
    let identifier: String?
    let id: String?
    let windowID: Int?
    init(_ request: Object) throws {
        guard !request.isEmpty, Set(request.keys).isSubset(of: ["identifier", "id", "window_id"]) else {
            throw Failure("target must constrain identifier, id or window_id; unknown selector fields are rejected")
        }
        identifier = try string(request, "identifier")
        id = try string(request, "id")
        windowID = request["window_id"] == nil ? nil : try integer(request, "window_id", range: 1...Int(UInt32.max))
    }
    func resolve(_ nodes: [Node], fingerprint: String, complete: Bool) throws -> Node {
        guard complete else { throw Failure("cannot validate target uniqueness in an incomplete AX tree; increase inspection bounds") }
        if let id, !id.hasPrefix("ax:\(fingerprint):") {
            throw Failure("assertion-failed", "stale ephemeral selector; re-inspect and use the new id")
        }
        let matches = nodes.filter { n in
            (identifier == nil || identifier == n.identifier) &&
            (id == nil || id == "ax:\(fingerprint):\(n.path)") &&
            (windowID == nil || windowID == n.windowID) &&
            (identifier != nil || id != nil || n.isWindow)
        }
        guard matches.count == 1 else {
            throw Failure("assertion-failed", matches.isEmpty ? "target not found" : "ambiguous target (\(matches.count) matches)",
                          ["match_count": matches.count])
        }
        return matches[0]
    }
}

final class Tree {
    let app: AXUIElement
    let identity: Identity
    let budget: Budget
    let maxDepth: Int
    let maxElements: Int
    let windowInfo: [WindowInfo]
    var nodes: [Node] = []
    var truncated = false
    var visited = Set<AXUIElement>()
    var fingerprint = ""
    init(identity: Identity, request: Object, budget: Budget) throws {
        try requireAX()
        try configureAXTimeout(budget)
        self.identity = identity; self.budget = budget
        maxDepth = try integer(request, "max_depth", default: 20, range: 1...64)
        maxElements = try integer(request, "max_elements", default: 2000, range: 1...10000)
        windowInfo = windows(identity.pid)
        app = AXUIElementCreateApplication(identity.pid)
        let result = AXUIElementSetMessagingTimeout(app, Float(min(0.2, budget.remaining)))
        guard result == .success else { throw Failure("AX messaging timeout could not be set: \(result.rawValue)") }
        try walk(app, path: "app", depth: 0, windowID: nil)
        try identity.revalidate()
        fingerprint = try treeFingerprint(nodes, identity: identity)
    }
    func walk(_ ax: AXUIElement, path: String, depth: Int, windowID: Int?) throws {
        try budget.check()
        guard nodes.count < maxElements else { truncated = true; return }
        guard !visited.contains(ax) else { return }
        visited.insert(ax)
        let role = try axAttribute(ax, kAXRoleAttribute, budget) as? String
        let title = try axAttribute(ax, kAXTitleAttribute, budget) as? String
        let description = try axAttribute(ax, kAXDescriptionAttribute, budget) as? String
        let identifier = try axAttribute(ax, kAXIdentifierAttribute, budget) as? String
        let rect = try axRect(ax, budget)
        let isWindow = role == kAXWindowRole
        var owningWindow = windowID
        if isWindow, let rect {
            let candidates = windowInfo.filter { w in
                abs(w.bounds.minX - rect.minX) < 1 && abs(w.bounds.minY - rect.minY) < 1 &&
                abs(w.bounds.width - rect.width) < 1 && abs(w.bounds.height - rect.height) < 1
            }
            if candidates.count == 1 { owningWindow = candidates[0].id }
            else if let title, !title.isEmpty {
                let titled = candidates.filter { $0.title == title }
                if titled.count == 1 { owningWindow = titled[0].id }
            }
        }
        let hidden = try axAttribute(ax, "AXHidden", budget) as? Bool
        let visible: Bool? = hidden.map { !$0 } ?? owningWindow.flatMap { id in windowInfo.first { $0.id == id }?.onScreen }
        let subrole = try axAttribute(ax, kAXSubroleAttribute, budget) as? String
        let value: Any = subrole == kAXSecureTextFieldSubrole
            ? null : safeValue(try axAttribute(ax, kAXValueAttribute, budget))
        nodes.append(Node(ax: ax, path: path, identifier: identifier, role: role,
                          label: (title?.isEmpty == false ? title : description), value: value,
                          enabled: try axAttribute(ax, kAXEnabledAttribute, budget) as? Bool,
                          focused: try axAttribute(ax, kAXFocusedAttribute, budget) as? Bool,
                          visible: visible, bounds: rect, windowID: owningWindow, isWindow: isWindow))
        // App windows and menus may not occur in AXChildren; traverse them first,
        // then deduplicate AXChildren by CF identity. Depth and count cap every path.
        if depth == 0 {
            let (children, cut) = try axElements(ax, kAXWindowsAttribute, limit: maxElements - nodes.count, budget)
            truncated = truncated || cut
            for (index, child) in children.enumerated() { try walk(child, path: "app/w\(index)", depth: 1, windowID: nil) }
            if let menu = try axAttribute(ax, kAXMenuBarAttribute, budget), CFGetTypeID(menu) == AXUIElementGetTypeID() {
                try walk(menu as! AXUIElement, path: "app/menu", depth: 1, windowID: nil)
            }
        }
        let (children, cut) = try axElements(ax, kAXChildrenAttribute, limit: maxElements - nodes.count, budget)
        truncated = truncated || cut
        if depth >= maxDepth { if !children.isEmpty { truncated = true }; return }
        for (index, child) in children.enumerated() {
            try walk(child, path: "\(path)/c\(index)", depth: depth + 1, windowID: owningWindow)
        }
    }
    func resolve(_ selector: Selector) throws -> Node {
        try selector.resolve(nodes, fingerprint: fingerprint, complete: !truncated)
    }
    var json: Object {
        ["identity": identity.json, "windows": windowInfo.map(\.json),
         "elements": nodes.map { $0.json(fingerprint) }, "truncated": truncated,
         "snapshot_id": fingerprint, "coordinate_space": "quartz-global-logical-points"]
    }
}

let inputActions: Set<String> = ["click", "double-click", "right-click", "hover", "move", "drag", "scroll", "type", "key"]
let accessibilityActions: Set<String> = ["click", "right-click", "menu", "focus", "type", "window"]

struct KeySpec {
    let code: CGKeyCode
    let flags: CGEventFlags
    let modifiers: [CGKeyCode]
}

func modifierFlag(_ code: CGKeyCode) -> CGEventFlags {
    switch code {
    case 55: return .maskCommand
    case 56: return .maskShift
    case 58: return .maskAlternate
    case 59: return .maskControl
    case 63: return .maskSecondaryFn
    default: return []
    }
}

func modifierSpec(_ request: Object) throws -> (CGEventFlags, [CGKeyCode]) {
    guard let raw = request["modifiers"] else { return ([], []) }
    guard let names = raw as? [String] else { throw Failure("modifiers must be an array of strings") }
    var flags: CGEventFlags = []; var codes: [CGKeyCode] = []
    for name in names {
        let pair: (CGEventFlags, CGKeyCode)
        switch name.lowercased() {
        case "command", "cmd": pair = (.maskCommand, 55)
        case "shift": pair = (.maskShift, 56)
        case "option", "alt": pair = (.maskAlternate, 58)
        case "control", "ctrl": pair = (.maskControl, 59)
        case "fn": pair = (.maskSecondaryFn, 63)
        default: throw Failure("unsupported", "unsupported modifier: \(name)")
        }
        guard !codes.contains(pair.1) else { throw Failure("duplicate modifier: \(name)") }
        flags.formUnion(pair.0); codes.append(pair.1)
    }
    return (flags, codes)
}

func keySpec(_ request: Object) throws -> KeySpec {
    let key = try string(request, "key", required: true)!
    let (flags, modifiers) = try modifierSpec(request)
    let named: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "backspace": 51, "delete": 51,
        "escape": 53, "esc": 53, "home": 115, "pageup": 116, "forwarddelete": 117,
        "end": 119, "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90]
    if let code = named[key.lowercased()] { return KeySpec(code: code, flags: flags, modifiers: modifiers) }
    // Explicit hardware codes avoid imposing a US layout on non-US keyboards.
    if key.hasPrefix("keycode:"), let code = UInt16(key.dropFirst(8)), code <= 127,
       ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(code) {
        return KeySpec(code: code, flags: flags, modifiers: modifiers)
    }
    if key.count == 1 {
        let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        if let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
            let layout = UnsafeRawPointer(CFDataGetBytePtr(data)).assumingMemoryBound(to: UCKeyboardLayout.self)
            for code in UInt16(0)...127 {
                var deadKey: UInt32 = 0; var length = 0
                var characters = [UniChar](repeating: 0, count: 8)
                let result = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                            &deadKey, characters.count, &length, &characters)
                if result == noErr, String(utf16CodeUnits: characters, count: length) == key {
                    return KeySpec(code: code, flags: flags, modifiers: modifiers)
                }
            }
        }
    }
    throw Failure("unsupported", "key is not a named key or an unmodified character in the current keyboard layout; use type for Unicode or keycode:N")
}

struct Action {
    let name: String
    let mode: String
    let selector: Selector?
    let point: CGPoint?
    let from: CGPoint?
    let to: CGPoint?
    let duration: Double
    let text: String?
    let key: KeySpec?
    let scrollX: Int32
    let scrollY: Int32
    let unit: CGScrollEventUnit
    let windowAction: String?
    let windowFrame: CGRect?
    let fullscreen: Bool?
    // A window-only constraint scopes explicit pointer coordinates; it does not
    // select an AX control. Control selectors and semantic actions need discovery.
    var usesCoordinateWindow: Bool {
        mode == "input" && selector?.identifier == nil && selector?.id == nil &&
        ((name == "drag" && from != nil && to != nil) ||
         (["click", "double-click", "right-click", "move", "hover", "scroll"].contains(name) && point != nil))
    }
    var requiresAXTree: Bool { mode == "accessibility" || (selector != nil && !usesCoordinateWindow) }
    init(_ request: Object) throws {
        name = try string(request, "action", required: true)!
        mode = try string(request, "mode", required: true)!
        guard ["input", "accessibility"].contains(mode) else { throw Failure("unsupported", "mode must be input or accessibility") }
        guard (mode == "input" ? inputActions : accessibilityActions).contains(name) else {
            throw Failure("unsupported", "\(name) is unsupported in \(mode) mode")
        }
        selector = try object(request, "target").map(Selector.init)
        point = try object(request, "point").map { try SwiftPoint($0) }
        from = try object(request, "from").map { try SwiftPoint($0) }
        to = try object(request, "to").map { try SwiftPoint($0) }
        duration = try number(request, "duration", default: 0.5, range: 0.01...10)
        if let raw = request["text"] {
            guard let value = raw as? String, value.utf16.count <= 16384 else { throw Failure("text must be a string of at most 16384 UTF-16 code units") }
            text = value
        } else { text = nil }
        if name == "type", text == nil { throw Failure("missing text") }
        key = name == "key" ? try keySpec(request) : nil
        scrollX = Int32(try integer(request, "delta_x", default: 0, range: -100_000...100_000))
        scrollY = Int32(try integer(request, "delta_y", default: 0, range: -100_000...100_000))
        let units = try string(request, "unit") ?? "pixel"
        guard ["pixel", "line"].contains(units) else { throw Failure("unsupported", "scroll unit must be pixel or line") }
        unit = units == "pixel" ? .pixel : .line
        windowAction = try string(request, "window_action")
        windowFrame = try object(request, "frame").map(frame)
        if let raw = request["value"] {
            guard let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw Failure("window value must be boolean") }
            fullscreen = n.boolValue
        } else { fullscreen = nil }
        if name == "drag", from == nil || to == nil { throw Failure("drag requires from and to points") }
        if mode == "input", ["click", "double-click", "right-click", "move", "hover"].contains(name), point == nil && selector == nil {
            throw Failure("\(name) requires point or target")
        }
        if mode == "accessibility", selector == nil && name != "focus" { throw Failure("\(name) requires target") }
        if name == "window" {
            guard let operation = windowAction, ["close", "minimize", "restore", "raise", "set-frame", "fullscreen"].contains(operation) else {
                throw Failure("unsupported", "window_action must be close, minimize, restore, raise, set-frame or fullscreen")
            }
            if operation == "set-frame", windowFrame == nil { throw Failure("set-frame requires frame") }
            if operation == "fullscreen", fullscreen == nil { throw Failure("fullscreen requires boolean value") }
        }
    }
}

// This name avoids shadowing Action.point during initialization.
func SwiftPoint(_ value: Object) throws -> CGPoint { try point(value) }

func dragPoints(from: CGPoint, to: CGPoint, duration: Double) -> [CGPoint] {
    let steps = max(2, Int(ceil(duration * 60)))
    return (1...steps).map { index in
        let t = Double(index) / Double(steps)
        return CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
    }
}

func unicodeChunks(_ text: String, limit: Int = 20) -> [[UniChar]] {
    var result: [[UniChar]] = []; var chunk: [UniChar] = []
    for scalar in text.unicodeScalars {
        let units = Array(String(scalar).utf16)
        if chunk.count + units.count > limit { result.append(chunk); chunk = [] }
        chunk.append(contentsOf: units)
    }
    if !chunk.isEmpty { result.append(chunk) }
    return result
}

func validatePoint(_ point: CGPoint, windows: [WindowInfo], windowID: Int?, displays: [CGRect]) throws {
    guard displays.contains(where: { $0.contains(point) }) else { throw Failure("assertion-failed", "point is outside active displays") }
    // CG window lists are front-to-back. A different window of the same process
    // must not satisfy a pinned window constraint merely by overlapping it.
    guard let owned = windows.first(where: { $0.onScreen && $0.bounds.contains(point) }),
          owned.layer == 0, windowID == nil || owned.id == windowID else {
        throw Failure("assertion-failed", "point is outside or occluded within the visible target-owned window")
    }
}

// A drag may move its target after mouse-down. Its initial press has the same
// geometry and hit-target requirements as a click; only later motion skips them.
func validatePointerSelection(_ node: Node, at point: CGPoint, dragging: Bool,
                              currentBounds: () throws -> CGRect?, hitMatches: () throws -> Bool) throws {
    guard !dragging else { return }
    if let retained = node.bounds {
        guard try currentBounds() == retained else {
            throw Failure("assertion-failed", "selected target bounds changed; re-inspect before input")
        }
        guard retained.contains(point) else { throw Failure("assertion-failed", "point is outside selected target bounds") }
    }
    guard try hitMatches() else { throw Failure("assertion-failed", "pointer hit does not belong to selected AX target") }
}

func displayBounds() -> [CGRect] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
    return ids.prefix(Int(count)).map(CGDisplayBounds)
}

/// Posts only complete, paired operations. The release stack contains only events
/// pressed by this invocation. Cleanup releases are allowed after focus loss.
final class InputSession: @unchecked Sendable {
    let lock = NSRecursiveLock()
    let source: CGEventSource
    var releases: [CGEvent] = []
    var cancelled = false
    var signalNumber: Int32?
    var eventCount = 0
    var signalSources: [DispatchSourceSignal] = []
    let poster: (CGEvent) -> Void
    init(poster: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }, installSignalHandlers: Bool = true) throws {
        guard let source = CGEventSource(stateID: .privateState) else { throw Failure("cannot create CGEvent source") }
        self.source = source
        self.poster = poster
        guard installSignalHandlers else { return }
        for signo in [SIGINT, SIGTERM, SIGHUP] {
            signal(signo, SIG_IGN)
            let handler = DispatchSource.makeSignalSource(signal: signo, queue: .global(qos: .userInteractive))
            handler.setEventHandler { [weak self] in
                guard let self else { return }
                self.lock.lock(); defer { self.lock.unlock() }
                self.cancelled = true; self.signalNumber = signo; self.releaseLocked()
            }
            handler.resume(); signalSources.append(handler)
        }
    }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw Failure("error", "input cancelled by signal", ["signal": signalNumber as Any? ?? null]) }
    }
    func post(_ event: CGEvent, release: CGEvent? = nil, completing: Bool = false,
              releaseLocation: CGPoint? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        try check()
        if let releaseLocation {
            guard let pending = releases.last else { throw Failure("missing pending pointer release") }
            // Keep the cleanup location and dragged event atomic with respect to
            // signal cleanup, which reads the same CGEvent under this lock.
            pending.location = releaseLocation
        }
        // Enqueue cleanup before posting down; signal cleanup uses the same lock.
        if let release { releases.append(release) }
        poster(event); eventCount += 1
        if completing { _ = releases.popLast() }
    }
    func releaseLocked() {
        for event in releases.reversed() { poster(event); eventCount += 1 }
        releases.removeAll()
    }
    func releaseAll() { lock.lock(); defer { lock.unlock() }; releaseLocked() }
    func mouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left, count: Int64 = 1) throws -> CGEvent {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
            throw Failure("cannot create mouse event")
        }
        event.setIntegerValueField(.mouseEventClickState, value: count)
        return event
    }
    func keyboard(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = []) throws -> CGEvent {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else {
            throw Failure("cannot create keyboard event")
        }
        event.flags = flags
        return event
    }
    func pause(_ seconds: Double, validate: () throws -> Void) throws {
        let until = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1e9)
        while DispatchTime.now().uptimeNanoseconds < until {
            try check(); try validate(); Thread.sleep(forTimeInterval: min(0.01, seconds))
        }
    }
    deinit { releaseAll(); signalSources.forEach { $0.cancel() } }
}

func waitForActivation(budget: Budget, isFrontmost: () -> Bool,
                       validateIdentity: () throws -> Void, pump: (Double) -> Void) throws {
    while true {
        try budget.check(); try validateIdentity()
        if isFrontmost() { return }
        pump(min(0.02, budget.remaining))
    }
}

func waitForActivation(_ identity: Identity, budget: Budget) throws {
    try waitForActivation(budget: budget,
                          isFrontmost: { NSWorkspace.shared.frontmostApplication?.processIdentifier == identity.pid },
                          validateIdentity: { try identity.revalidate() },
                          pump: { RunLoop.current.run(until: Date(timeIntervalSinceNow: $0)) })
}

func ensureFocus(_ identity: Identity, budget: Budget) throws {
    try budget.check(); try identity.revalidate()
    // NSWorkspace's snapshot can stay stale while a synchronous input operation
    // runs. Ask AX for the current focused application before every dispatch.
    let system = AXUIElementCreateSystemWide()
    guard let focused = try axAttribute(system, kAXFocusedApplicationAttribute, budget),
          CFGetTypeID(focused) == AXUIElementGetTypeID() else {
        throw Failure("assertion-failed", "cannot observe the frontmost application")
    }
    var frontmostPID: pid_t = 0
    guard AXUIElementGetPid(focused as! AXUIElement, &frontmostPID) == .success,
          frontmostPID == identity.pid else {
        throw Failure("assertion-failed", "target is not frontmost; input was refused or interrupted", ["focus_lost": true])
    }
    if let session = CGSessionCopyCurrentDictionary() as? Object {
        if (session["CGSSessionScreenIsLocked"] as? Bool) == true || (session[kCGSessionOnConsoleKey as String] as? Bool) == false {
            throw Failure("assertion-failed", "GUI session is locked or off-console")
        }
    } else { throw Failure("unsupported", "no interactive WindowServer session") }
}

func requireInputAccess() throws {
    guard CGPreflightPostEventAccess() else { throw Failure("permission-required", "post-event access is required; helper never prompts") }
    try requireAX()
    // Refuse to disturb physical input already held by the user/another client.
    let heldButtons = [CGMouseButton.left, .right, .center].contains { CGEventSource.buttonState(.combinedSessionState, button: $0) }
    let flags = CGEventSource.flagsState(.combinedSessionState)
    guard !heldButtons, flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]).isEmpty else {
        throw Failure("assertion-failed", "existing held mouse button or modifier would contaminate input")
    }
}

func pointerHit(_ point: CGPoint, pid: pid_t, budget: Budget) throws -> AXUIElement {
    try budget.check()
    var hit: AXUIElement?
    let code = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit)
    try budget.check()
    guard code == .success, let hit else { throw Failure("assertion-failed", "cannot validate pointer hit target (AX \(code.rawValue))") }
    var hitPID: pid_t = 0
    guard AXUIElementGetPid(hit, &hitPID) == .success, hitPID == pid else {
        throw Failure("assertion-failed", "point is occluded by another process")
    }
    return hit
}

// Injection is confined to native fixtures; production uses these exact defaults.
struct InputEnvironment {
    var requireAccess: () throws -> Void = requireInputAccess
    var validateFocus: (Identity, Budget) throws -> Void = { try ensureFocus($0, budget: $1) }
    var ownedWindows: (pid_t) -> [WindowInfo] = windows
    var displays: () -> [CGRect] = displayBounds
    var hit: (CGPoint, pid_t, Budget) throws -> AXUIElement = { try pointerHit($0, pid: $1, budget: $2) }
    var session: () throws -> InputSession = { try InputSession() }
}

// Both the real executor and fixtures use this lazy dispatch, so a coordinate
// test can fail if discovery is ever added back before the input path.
func performAction<Snapshot>(_ action: Action, buildTree: () throws -> Snapshot,
                             semantic: (Snapshot) throws -> Object,
                             pointer: (Snapshot?) throws -> Object) throws -> Object {
    let tree = action.requiresAXTree ? try buildTree() : nil
    if action.mode == "accessibility" { return try semantic(tree!) }
    return try pointer(tree)
}

func input(_ action: Action, identity: Identity, tree: Tree?, budget: Budget,
           environment: InputEnvironment = InputEnvironment()) throws -> Object {
    try environment.requireAccess()
    try environment.validateFocus(identity, budget)
    let node = try (action.usesCoordinateWindow ? nil : action.selector).map { selector -> Node in
        guard let tree else { throw Failure("missing AX snapshot") }
        return try tree.resolve(selector)
    }
    if node?.enabled == false || node?.visible == false { throw Failure("assertion-failed", "target is disabled or not visible") }
    let windowID = node?.windowID ?? (action.usesCoordinateWindow ? action.selector?.windowID : nil)
    let activeDisplays = environment.displays()
    func validate() throws { try environment.validateFocus(identity, budget) }
    func validateLocation(_ p: CGPoint, dragging: Bool = false) throws {
        try validate()
        try validatePoint(p, windows: environment.ownedWindows(identity.pid), windowID: windowID, displays: activeDisplays)
        // AX hit testing catches overlays owned by other apps and target mismatch.
        let hit = try environment.hit(p, identity.pid, budget)
        if let node, let target = node.ax {
            try validatePointerSelection(node, at: p, dragging: dragging,
                                         currentBounds: { try axRect(target, budget) }, hitMatches: {
                var candidate: AXUIElement? = hit
                var matched = false
                for _ in 0..<64 {
                    guard let current = candidate else { break }
                    if CFEqual(current, target) { matched = true; break }
                    guard let parent = try axAttribute(current, kAXParentAttribute, budget), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                    candidate = (parent as! AXUIElement)
                }
                return matched
            })
        }
    }
    let center = node?.bounds.map { CGPoint(x: $0.midX, y: $0.midY) }
    let location = action.point ?? center
    if let p = action.point, let bounds = node?.bounds, !bounds.contains(p) {
        throw Failure("assertion-failed", "point is outside selected target bounds")
    }
    let session = try environment.session()
    defer { session.releaseAll() }
    var result: Object = ["mode": "input", "action": action.name, "completion": "input-dispatched",
                          "identity": identity.json, "coordinate_space": "quartz-global-logical-points"]
    if let node, let tree { result["target"] = node.json(tree.fingerprint) }
    if action.usesCoordinateWindow {
        result["target_validation"] = "coordinate-owned-window-and-ax-hit"
        if let windowID { result["window_id"] = windowID }
    }
    do {
        switch action.name {
        case "move", "hover":
            guard let p = location else { throw Failure("missing pointer location") }
            try validateLocation(p)
            try session.post(session.mouse(.mouseMoved, at: p))
            result["point"] = ["x": p.x, "y": p.y]
        case "click", "double-click", "right-click":
            guard let p = location else { throw Failure("target has no bounds; supply a validated point") }
            let right = action.name == "right-click"
            let count = action.name == "double-click" ? 2 : 1
            for click in 1...count {
                try validateLocation(p)
                let up = try session.mouse(right ? .rightMouseUp : .leftMouseUp, at: p, button: right ? .right : .left, count: Int64(click))
                let down = try session.mouse(right ? .rightMouseDown : .leftMouseDown, at: p, button: right ? .right : .left, count: Int64(click))
                try session.post(down, release: up)
                try session.pause(0.025, validate: validate)
                try session.post(up, completing: true)
                if click < count { try session.pause(0.05, validate: validate) }
            }
            result["point"] = ["x": p.x, "y": p.y]
        case "drag":
            let from = action.from!, to = action.to!
            if let bounds = node?.bounds, !bounds.contains(from) { throw Failure("assertion-failed", "drag origin is outside target bounds") }
            try validateLocation(from)
            let points = dragPoints(from: from, to: to, duration: action.duration)
            // Validate the entire route before pressing. No cross-app drops.
            let routeWindows = environment.ownedWindows(identity.pid)
            for p in points {
                try budget.check()
                try validatePoint(p, windows: routeWindows, windowID: windowID, displays: activeDisplays)
            }
            try validateLocation(from)
            let release = try session.mouse(.leftMouseUp, at: from)
            try session.post(session.mouse(.leftMouseDown, at: from), release: release)
            for p in points {
                try session.pause(action.duration / Double(points.count), validate: validate)
                try validateLocation(p, dragging: true)
                try session.post(session.mouse(.leftMouseDragged, at: p), releaseLocation: p)
            }
            try validate()
            try session.post(session.mouse(.leftMouseUp, at: to), completing: true)
            result["from"] = ["x": from.x, "y": from.y]; result["to"] = ["x": to.x, "y": to.y]
        case "scroll":
            // With a target/point, position the cursor explicitly in input mode.
            let p = location ?? CGEvent(source: nil)?.location
            guard let p else { throw Failure("cannot determine pointer location") }
            try validateLocation(p)
            if location != nil { try session.post(session.mouse(.mouseMoved, at: p)); try validateLocation(p) }
            guard let event = CGEvent(scrollWheelEvent2Source: session.source, units: action.unit, wheelCount: 2,
                                      wheel1: action.scrollY, wheel2: action.scrollX, wheel3: 0) else { throw Failure("cannot create scroll event") }
            event.location = p; try session.post(event)
            result["point"] = ["x": p.x, "y": p.y]
        case "type", "key":
            // Selecting a field does not silently focus it. Verify actual AX focus.
            let app = tree?.app ?? AXUIElementCreateApplication(identity.pid)
            _ = AXUIElementSetMessagingTimeout(app, 0.2)
            guard let focused = try axAttribute(app, kAXFocusedUIElementAttribute, budget), CFGetTypeID(focused) == AXUIElementGetTypeID() else {
                throw Failure("assertion-failed", "target app has no observable focused element")
            }
            if let selected = node?.ax, !CFEqual(focused, selected) { throw Failure("assertion-failed", "selected element is not focused") }
            if action.name == "type" {
                for chunk in unicodeChunks(action.text!) {
                    try validate()
                    guard let currentFocus = try axAttribute(app, kAXFocusedUIElementAttribute, budget), CFEqual(currentFocus, focused) else {
                        throw Failure("assertion-failed", "focused element changed during text input")
                    }
                    let down = try session.keyboard(0, down: true), up = try session.keyboard(0, down: false)
                    chunk.withUnsafeBufferPointer { ptr in
                        down.keyboardSetUnicodeString(stringLength: ptr.count, unicodeString: ptr.baseAddress)
                        up.keyboardSetUnicodeString(stringLength: ptr.count, unicodeString: ptr.baseAddress)
                    }
                    try session.post(down, release: up); try validate(); try session.post(up, completing: true)
                }
                result["utf16_count"] = action.text!.utf16.count
            } else {
                let key = action.key!
                var heldFlags: CGEventFlags = []
                for code in key.modifiers {
                    try validate()
                    let priorFlags = heldFlags
                    heldFlags.formUnion(modifierFlag(code))
                    try session.post(session.keyboard(code, down: true, flags: heldFlags),
                                     release: session.keyboard(code, down: false, flags: priorFlags))
                }
                try validate()
                let up = try session.keyboard(key.code, down: false, flags: key.flags)
                try session.post(session.keyboard(key.code, down: true, flags: key.flags), release: up)
                try session.pause(0.025, validate: validate)
                try session.post(up, completing: true)
                session.releaseAll()
            }
        default: throw Failure("unsupported", "unimplemented input action")
        }
        try session.check(); try validate()
        session.releaseAll()
        result["events_posted"] = session.eventCount; result["held_inputs_released"] = true
        return result
    } catch let failure as Failure {
        session.releaseAll()
        var data = failure.data
        data["events_posted"] = session.eventCount; data["held_inputs_released"] = true
        data["partial_dispatch"] = session.eventCount > 0; data["mode"] = "input"
        throw Failure(failure.status, failure.message, data)
    }
}

func axSet(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef, budget: Budget) throws {
    try budget.check()
    var settable = DarwinBoolean(false)
    let check = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
    guard check == .success, settable.boolValue else { throw Failure("unsupported", "AX attribute is not settable: \(attribute)") }
    try budget.check()
    let result = AXUIElementSetAttributeValue(element, attribute as CFString, value)
    guard result == .success else {
        throw Failure(result == .cannotComplete ? "timed-out" : "error", "AX set \(attribute) failed: \(result.rawValue)",
                      ["outcome_unknown": true, "may_have_dispatched": true])
    }
}

func axPerform(_ element: AXUIElement, _ action: String, budget: Budget) throws {
    try budget.check()
    var names: CFArray?
    let copied = AXUIElementCopyActionNames(element, &names)
    guard copied == .success else {
        throw Failure(copied == .cannotComplete ? "timed-out" : "unsupported", "AX actions unavailable: \(copied.rawValue)")
    }
    guard (names as? [String])?.contains(action) == true else { throw Failure("unsupported", "element does not support AX action \(action)") }
    try budget.check()
    let result = AXUIElementPerformAction(element, action as CFString)
    guard result == .success else {
        throw Failure(result == .cannotComplete ? "timed-out" : "error", "AX action \(action) failed: \(result.rawValue)",
                      ["outcome_unknown": true, "may_have_dispatched": true])
    }
}

func accessibility(_ action: Action, identity: Identity, tree: Tree, budget: Budget) throws -> Object {
    let node = try action.selector.map(tree.resolve)
    let element = node?.ax ?? tree.app
    try identity.revalidate(); try budget.check()
    if node?.enabled == false { throw Failure("assertion-failed", "selected element is disabled") }
    var result: Object = ["mode": "accessibility", "action": action.name, "completion": "ax-call-completed", "identity": identity.json]
    if let node { result["target"] = node.json(tree.fingerprint) }
    // AX can act on a background application, but never mislabel it as real input.
    switch action.name {
    case "click", "menu":
        try axPerform(element, kAXPressAction, budget: budget)
    case "right-click":
        try axPerform(element, kAXShowMenuAction, budget: budget)
    case "type":
        try axSet(element, kAXValueAttribute, action.text! as CFString, budget: budget)
        let actual = try axAttribute(element, kAXValueAttribute, budget) as? String
        guard actual == action.text else { throw Failure("assertion-failed", "AX value did not match requested text after setting") }
        result["text_operation"] = "replace-AXValue"
    case "focus":
        try axSet(tree.app, kAXFrontmostAttribute, kCFBooleanTrue, budget: budget)
        try waitForActivation(identity, budget: budget)
        if let node {
            if node.isWindow {
                try axPerform(element, kAXRaiseAction, budget: budget)
                try axSet(element, kAXMainAttribute, kCFBooleanTrue, budget: budget)
            } else { try axSet(element, kAXFocusedAttribute, kCFBooleanTrue, budget: budget) }
        }
        try ensureFocus(identity, budget: budget)
        if let node, !node.isWindow {
            guard let focused = try axAttribute(tree.app, kAXFocusedUIElementAttribute, budget), CFEqual(focused, element) else {
                throw Failure("assertion-failed", "requested AX focus was not observed")
            }
        }
    case "window":
        guard node?.isWindow == true else { throw Failure("assertion-failed", "window operation requires an AXWindow selector") }
        switch action.windowAction! {
        case "close":
            guard let close = try axAttribute(element, kAXCloseButtonAttribute, budget), CFGetTypeID(close) == AXUIElementGetTypeID() else {
                throw Failure("unsupported", "window has no AX close button")
            }
            try axPerform(close as! AXUIElement, kAXPressAction, budget: budget)
        case "minimize", "restore":
            try axSet(element, kAXMinimizedAttribute, action.windowAction == "minimize" ? kCFBooleanTrue : kCFBooleanFalse, budget: budget)
        case "raise": try axPerform(element, kAXRaiseAction, budget: budget)
        case "fullscreen":
            try axSet(element, "AXFullScreen", action.fullscreen! ? kCFBooleanTrue : kCFBooleanFalse, budget: budget)
        case "set-frame":
            var origin = action.windowFrame!.origin; var size = action.windowFrame!.size
            guard let position = AXValueCreate(.cgPoint, &origin), let dimensions = AXValueCreate(.cgSize, &size) else {
                throw Failure("cannot create AX geometry")
            }
            // Two API calls are not transactional. Preserve evidence of partial work.
            try axSet(element, kAXPositionAttribute, position, budget: budget)
            do { try axSet(element, kAXSizeAttribute, dimensions, budget: budget) }
            catch let failure as Failure {
                throw Failure(failure.status, failure.message, ["partial_dispatch": true, "position_set": true])
            }
        default: throw Failure("unsupported", "unsupported window operation")
        }
        result["window_action"] = action.windowAction
    default: throw Failure("unsupported", "unsupported AX action")
    }
    // Closing the final window can terminate an application; report target loss.
    try identity.revalidate(); try budget.check()
    return result
}

// Callback-based ScreenCaptureKit APIs work with an ordinary swiftc executable.
// Pump the run loop, so a callback delivered on main cannot deadlock the helper.
final class Completion<T>: @unchecked Sendable {
    let lock = NSLock()
    var result: Result<T, Error>?
    func finish(_ result: Result<T, Error>) { lock.lock(); defer { lock.unlock() }; self.result = result }
    func wait(_ budget: Budget) throws -> T {
        while true {
            lock.lock(); let current = result; lock.unlock()
            if let current { return try current.get() }
            try budget.check()
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: min(0.01, budget.remaining)))
        }
    }
}

func validateOutput(_ path: String) throws {
    guard path.hasPrefix("/"), URL(fileURLWithPath: path).pathExtension.lowercased() == "png" else {
        throw Failure("capture output must be an absolute .png path")
    }
    var info = stat()
    if lstat(path, &info) == 0 { throw Failure("capture output already exists; refusing overwrite") }
    guard errno == ENOENT else { throw Failure("cannot inspect capture output: \(String(cString: strerror(errno)))") }
    var directory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path, isDirectory: &directory), directory.boolValue else {
        throw Failure("capture output parent directory must already exist")
    }
}

func writeExclusive(_ bytes: Data, to path: String) throws {
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { throw Failure("cannot create capture output: \(String(cString: strerror(errno)))") }
    var complete = false
    defer { close(fd); if !complete { unlink(path) } }
    try bytes.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw Failure("cannot write capture output: \(String(cString: strerror(errno)))") }
            offset += count
        }
    }
    complete = true
}

func capture(_ request: Object, identity: Identity, budget: Budget) throws -> Object {
    let output = try string(request, "output", required: true)!
    try validateOutput(output)
    let selector = try object(request, "target").map(Selector.init)
    let requestedID = request["window_id"] == nil ? nil : try integer(request, "window_id", range: 1...Int(UInt32.max))
    var windowID = requestedID
    if let selector {
        if selector.identifier != nil || selector.id != nil {
            let tree = try Tree(identity: identity, request: request, budget: budget)
            let node = try tree.resolve(selector)
            guard let ownedID = node.windowID else { throw Failure("unsupported", "selected AX target cannot be mapped uniquely to an owned CG window") }
            if let requestedID, ownedID != requestedID { throw Failure("assertion-failed", "conflicting capture window selectors") }
            windowID = ownedID
        } else {
            if let requestedID, requestedID != selector.windowID { throw Failure("assertion-failed", "conflicting capture window selectors") }
            windowID = selector.windowID
        }
    }
    let candidates = windows(identity.pid).filter { $0.layer == 0 && $0.onScreen && (windowID == nil || $0.id == windowID) }
    guard candidates.count == 1 else {
        throw Failure("assertion-failed", candidates.isEmpty ? "no visible owned capture window" : "ambiguous capture window; specify window_id", ["match_count": candidates.count])
    }
    let owned = candidates[0]
    guard CGPreflightScreenCaptureAccess() else { throw Failure("permission-required", "Screen Recording permission is required; helper never prompts") }
    guard #available(macOS 14.0, *) else { throw Failure("unsupported", "owned-window screenshots require macOS 14 ScreenCaptureKit") }
    try identity.revalidate(); try budget.check()
    let content = Completion<SCShareableContent>()
    SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { value, error in
        if let error { content.finish(.failure(error)) }
        else if let value { content.finish(.success(value)) }
        else { content.finish(.failure(Failure("ScreenCaptureKit returned no shareable content"))) }
    }
    let shareable = try content.wait(budget)
    guard let window = shareable.windows.first(where: {
        $0.windowID == CGWindowID(owned.id) && $0.owningApplication?.processID == identity.pid && $0.isOnScreen
    }) else { throw Failure("target-lost", "owned window is no longer available to ScreenCaptureKit") }
    try identity.revalidate(); try budget.check()
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let info = SCShareableContent.info(for: filter)
    let config = SCStreamConfiguration()
    let width = ceil(info.contentRect.width * CGFloat(info.pointPixelScale))
    let height = ceil(info.contentRect.height * CGFloat(info.pointPixelScale))
    guard width.isFinite, height.isFinite, width > 0, height > 0,
          width <= 16384, height <= 16384, width * height <= 100_000_000 else {
        throw Failure("unsupported", "capture dimensions exceed bounded PNG capture limits")
    }
    config.width = Int(width); config.height = Int(height)
    config.showsCursor = false
    config.ignoreShadowsSingleWindow = true
    let image = Completion<CGImage>()
    SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { value, error in
        if let error { image.finish(.failure(error)) }
        else if let value { image.finish(.success(value)) }
        else { image.finish(.failure(Failure("ScreenCaptureKit returned no image"))) }
    }
    let captured = try image.wait(budget)
    try identity.revalidate(); try budget.check()
    guard windows(identity.pid).contains(where: { $0.id == owned.id && $0.onScreen }) else {
        throw Failure("target-lost", "owned window disappeared during capture")
    }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        throw Failure("cannot create PNG encoder")
    }
    CGImageDestinationAddImage(destination, captured, nil)
    guard CGImageDestinationFinalize(destination) else { throw Failure("PNG encoding failed") }
    try budget.check()
    try writeExclusive(data as Data, to: output)
    return ["identity": identity.json, "window_id": owned.id, "bounds": jsonRect(window.frame),
            "output": output, "artifacts": [output], "format": "png", "width": captured.width,
            "height": captured.height, "point_pixel_scale": info.pointPixelScale,
            "capture_scope": "desktop-independent-owned-window", "includes_cursor": false]
}

func doctor() -> Object {
    let displays = displayBounds()
    let session = CGSessionCopyCurrentDictionary() as? Object
    let onConsole = session?[kCGSessionOnConsoleKey as String] as? Bool
    let locked = session?["CGSSessionScreenIsLocked"] as? Bool
    let screenCapture: Bool
    if #available(macOS 14.0, *) { screenCapture = true } else { screenCapture = false }
    return ["os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "helper_pid": Int(getpid()), "permissions": ["accessibility": AXIsProcessTrusted(),
                "screen_capture": CGPreflightScreenCaptureAccess(), "post_event": CGPreflightPostEventAccess()],
            "session": ["available": session != nil, "on_console": onConsole as Any? ?? null,
                        "locked": locked as Any? ?? null, "active_display_count": displays.count],
            "displays": displays.map { jsonRect($0) },
            "capabilities": ["operations": ["doctor", "identity", "inspect", "act", "capture"],
                             "input": inputActions.sorted(), "accessibility": accessibilityActions.sorted(),
                             "window_capture": screenCapture, "capture_requires": "macOS 14 and Screen Recording permission",
                             "permission_prompts": false, "app_launch": false,
                             "completion": "dispatch or AX call only; app handling and presentation require external assertions"],
            "coordinate_space": "quartz-global-logical-points"]
}

func execute(_ request: Object) throws -> Object {
    let operation = try string(request, "operation", required: true)!
    let budget = Budget(seconds: try number(request, "timeout", default: 5, range: 0.1...30))
    guard ["doctor", "identity", "inspect", "act", "capture"].contains(operation) else {
        throw Failure("unsupported", "unsupported operation: \(operation)")
    }
    if operation == "doctor" { return doctor() }
    let pid = pid_t(try integer(request, "pid", range: 1...Int(Int32.max)))
    let identity = Identity.read(pid)
    let expected = try object(request, "expected_identity")
    if operation == "identity" {
        if expected != nil { try identity.validate(expected) }
        return identity.json
    }
    // Validate all action syntax before touching AX or the event subsystem.
    let action = operation == "act" ? try Action(request) : nil
    try identity.validate(expected)
    try identity.revalidate()
    if let action, action.name == "focus", action.mode == "accessibility", action.selector == nil {
        try requireAX()
        try configureAXTimeout(budget)
        guard let application = NSRunningApplication(processIdentifier: identity.pid),
              application.activate(options: [.activateAllWindows]) else {
            throw Failure("assertion-failed", "target application activation was rejected")
        }
        // NSWorkspace receives activation changes through the run loop.
        try waitForActivation(identity, budget: budget)
        try ensureFocus(identity, budget: budget)
        return ["identity": identity.json, "mode": "accessibility", "action": "focus",
                "completion": "application-frontmost-observed"]
    }
    if operation == "inspect", let flag = request["windows_only"] {
        guard CFGetTypeID(flag as CFTypeRef) == CFBooleanGetTypeID(), let enabled = flag as? Bool else {
            throw Failure("windows_only must be a boolean")
        }
        if enabled {
            let ownedWindows = windows(identity.pid)
            try identity.revalidate()
            return ["identity": identity.json, "windows": ownedWindows.map(\.json),
                    "elements": [], "truncated": true, "inspection_scope": "windows-only",
                    "coordinate_space": "quartz-global-logical-points"]
        }
    }
    if operation == "inspect" || operation == "act" {
        try configureAXTimeout(budget)
    }
    switch operation {
    case "inspect": return try Tree(identity: identity, request: request, budget: budget).json
    case "capture": return try capture(request, identity: identity, budget: budget)
    case "act":
        let action = action!
        return try performAction(action,
            buildTree: { try Tree(identity: identity, request: request, budget: budget) },
            semantic: { try accessibility(action, identity: identity, tree: $0, budget: budget) },
            pointer: { try input(action, identity: identity, tree: $0, budget: budget) })
    default: throw Failure("unsupported", "unsupported operation")
    }
}

func configureAXTimeout(_ budget: Budget) throws {
    try budget.check()
    // An application element's timeout does NOT propagate to its children.
    // A system-wide element sets this helper process's global AX timeout.
    let timeout = AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Float(min(0.2, budget.remaining)))
    guard timeout == .success else { throw Failure("cannot configure global AX messaging timeout: \(timeout.rawValue)") }
}

func readRequest() throws -> Object {
    var bytes = Data()
    let budget = Budget(seconds: 5)
    var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
        try budget.check()
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
        let ready = poll(&descriptor, 1, Int32(min(100, budget.remaining * 1000)))
        if ready < 0 && errno == EINTR { continue }
        guard ready >= 0 else { throw Failure("stdin poll failed") }
        if ready == 0 { continue }
        let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        guard count >= 0 else { throw Failure("stdin read failed") }
        if count == 0 { break }
        bytes.append(contentsOf: buffer.prefix(count))
        guard bytes.count <= 1_048_576 else { throw Failure("request exceeds 1 MiB limit") }
    }
    guard !bytes.isEmpty else { throw Failure("stdin must contain exactly one JSON request") }
    let decoded: Any
    do { decoded = try JSONSerialization.jsonObject(with: bytes) }
    catch { throw Failure("invalid JSON request: \(error.localizedDescription)") }
    guard let request = decoded as? Object else { throw Failure("request must be a JSON object") }
    return request
}

func nativeMain() {
        let started = DispatchTime.now().uptimeNanoseconds
        var request: Object = [:]
        var response: Object = ["schema_version": 1]
        var code: Int32 = 0
        do {
            request = try readRequest()
            response["data"] = try execute(request)
            response["status"] = "ok"
        } catch let error as Failure {
            response["status"] = error.status; response["error"] = error.message; response["data"] = error.data
            code = 1
        } catch {
            response["status"] = "error"; response["error"] = error.localizedDescription; response["data"] = Object()
            code = 1
        }
        response["run_id"] = request["run_id"] as? String ?? null as Any
        response["action_id"] = request["action_id"] as? String ?? null as Any
        response["started_monotonic_ns"] = started
        response["ended_monotonic_ns"] = DispatchTime.now().uptimeNanoseconds
        do {
            let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys, .fragmentsAllowed])
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
        } catch {
            FileHandle.standardOutput.write(Data("{\"schema_version\":1,\"status\":\"error\",\"data\":{},\"error\":\"response encoding failed\"}\n".utf8))
            code = 1
        }
        exit(code)
}

#if !NATIVE_UI_TESTS
nativeMain()
#endif
