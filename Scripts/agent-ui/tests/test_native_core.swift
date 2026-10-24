// Compiled with native.swift and -D NATIVE_UI_TESTS by test_native.py.
// Uses fixture nodes and an injected event sink. Never posts system input.
import Foundation
import CoreGraphics

struct TestError: Error { let message: String }
func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestError(message: message) }
}
func failure(_ status: String, _ body: () throws -> Void) throws {
    do { try body() }
    catch let error as Failure {
        try require(error.status == status, "expected \(status), got \(error.status): \(error.message)")
        return
    }
    throw TestError(message: "expected failure \(status)")
}
func fixtureNode(_ path: String, identifier: String? = "button", window: Int? = 7,
                 isWindow: Bool = false, x: Double = 10) -> Node {
    Node(ax: nil, path: path, identifier: identifier, role: isWindow ? "AXWindow" : "AXButton",
         label: "Control", value: NSNull(), enabled: true, focused: false, visible: true,
         bounds: CGRect(x: x, y: 20, width: 100, height: 40), windowID: window, isWindow: isWindow)
}

func runCoreTests() throws {
    let identity = Identity(pid: 123, alive: true, executable: "/fixture/app", start: "99:123", bundle: nil)
    let first = fixtureNode("app/w0/c0")
    let other = fixtureNode("app/w1/c0", window: 8)
    let window = fixtureNode("app/w0", identifier: nil, isWindow: true)
    let nodes = [window, first, other]
    let fingerprint = try treeFingerprint(nodes, identity: identity)
    try require(try treeFingerprint(nodes, identity: identity) == fingerprint, "fingerprints must be deterministic")
    let moved = [window, fixtureNode("app/w0/c0", x: 11), other]
    try require(try treeFingerprint(moved, identity: identity) != fingerprint, "geometry changes must invalidate ephemeral ids")
    let reused = Identity(pid: 123, alive: true, executable: "/fixture/app", start: "100:1", bundle: nil)
    try require(try treeFingerprint(nodes, identity: reused) != fingerprint, "PID reuse must invalidate ephemeral ids")
    try failure("assertion-failed") {
        _ = try Selector(["identifier": "button"]).resolve(nodes, fingerprint: fingerprint, complete: true)
    }
    let unique = try Selector(["identifier": "button", "window_id": 7]).resolve(nodes, fingerprint: fingerprint, complete: true)
    try require(unique.path == first.path, "window must scope repeated identifiers")
    let resolvedWindow = try Selector(["window_id": 7]).resolve(nodes, fingerprint: fingerprint, complete: true)
    try require(resolvedWindow.isWindow, "window-only selector must select AXWindow, not its children")
    let id = "ax:\(fingerprint):\(first.path)"
    try require(try Selector(["id": id]).resolve(nodes, fingerprint: fingerprint, complete: true).path == first.path, "ephemeral resolution failed")
    try failure("assertion-failed") { _ = try Selector(["id": id]).resolve(moved, fingerprint: "changed", complete: true) }
    try failure("error") { _ = try Selector(["identifier": "button", "window_id": 7]).resolve(nodes, fingerprint: fingerprint, complete: false) }
    try failure("error") { _ = try Selector([:]) }
    try failure("error") { _ = try Selector(["label": "Control"]) }
    try failure("error") { _ = try Selector(["window_id": true]) }
    try failure("assertion-failed") {
        _ = try Selector(["identifier": "different", "id": id]).resolve(nodes, fingerprint: fingerprint, complete: true)
    }

    try identity.validate(["pid": 123, "executable_path": "/fixture/app", "process_start_identity": "99:123"])
    try failure("target-lost") { try identity.validate(["process_start_identity": "stale"]) }
    try failure("target-lost") { try identity.validate(["bundle_id": "unknown"]) }
    try failure("error") { try identity.validate(["typo": "anything"]) }
    try failure("error") { try identity.validate([:]) }
    try failure("error") { _ = try number(["timeout": true], "timeout") }
    try failure("error") { _ = try integer(["pid": 1.5], "pid") }
    try failure("error") { _ = try number(["x": Double.infinity], "x") }
    try failure("error") { _ = try frame(["x": 0, "y": 0, "width": 0, "height": 4]) }

    let owned = WindowInfo(id: 7, bounds: CGRect(x: -200, y: 0, width: 200, height: 200), title: nil, onScreen: true, layer: 0)
    let displays = [CGRect(x: -200, y: 0, width: 200, height: 200), CGRect(x: 0, y: 0, width: 500, height: 500)]
    try validatePoint(CGPoint(x: -10, y: 30), windows: [owned], windowID: 7, displays: displays)
    try failure("assertion-failed") { try validatePoint(CGPoint(x: -10, y: 30), windows: [owned], windowID: 8, displays: displays) }
    try failure("assertion-failed") { try validatePoint(CGPoint(x: 10, y: 30), windows: [owned], windowID: nil, displays: displays) }
    try failure("assertion-failed") { try validatePoint(CGPoint(x: -300, y: 30), windows: [owned], windowID: nil, displays: displays) }
    let pressPoint = CGPoint(x: 20, y: 30)
    try validatePointerSelection(first, at: pressPoint, dragging: false,
                                 currentBounds: { first.bounds }, hitMatches: { true })
    // A drag's first press must reject a different control even if its bounds
    // overlap the selected target; later motion may follow a moving control.
    try failure("assertion-failed") {
        try validatePointerSelection(first, at: pressPoint, dragging: false,
                                     currentBounds: { first.bounds }, hitMatches: { false })
    }
    try failure("assertion-failed") {
        try validatePointerSelection(first, at: pressPoint, dragging: false,
                                     currentBounds: { first.bounds!.offsetBy(dx: 1, dy: 0) }, hitMatches: { true })
    }
    try failure("assertion-failed") {
        try validatePointerSelection(first, at: CGPoint(x: 500, y: 500), dragging: false,
                                     currentBounds: { first.bounds }, hitMatches: { true })
    }
    try validatePointerSelection(first, at: CGPoint(x: 500, y: 500), dragging: true,
                                 currentBounds: { throw TestError(message: "drag motion revalidated original geometry") },
                                 hitMatches: { throw TestError(message: "drag motion required original target hit") })
    let route = dragPoints(from: CGPoint(x: -190, y: 20), to: CGPoint(x: -10, y: 80), duration: 0.5)
    try require(route.count == 30 && route.last == CGPoint(x: -10, y: 80), "drag must finish at exact endpoint")
    try require(zip(route, route.dropFirst()).allSatisfy { $0.x < $1.x && $0.y < $1.y }, "drag route must be monotonic")

    // Execute the production lazy-dispatch and pointer path. Every OS-facing
    // dependency is injected; CGEvents go only to this local array.
    let coordinateRequest: Object = ["action": "drag", "mode": "input", "target": ["window_id": 7],
                                     "from": ["x": -190, "y": 20], "to": ["x": -10, "y": 80], "duration": 0.01]
    let coordinateDrag = try Action(coordinateRequest)
    var coordinateEvents: [(CGEventType, CGPoint)] = []
    var focusChecks = 0, windowChecks = 0, accessChecks = 0
    var hitPoints: [CGPoint] = []
    let fixtureHit = AXUIElementCreateApplication(identity.pid)
    let environment = InputEnvironment(
        requireAccess: { accessChecks += 1 },
        validateFocus: { pinned, budget in
            try budget.check()
            try require(pinned.start == identity.start && pinned.executable == identity.executable,
                        "coordinate dispatch lost exact process identity")
            focusChecks += 1
        },
        ownedWindows: { pid in windowChecks += 1; return pid == identity.pid ? [owned] : [] },
        displays: { displays },
        hit: { p, pid, budget in
            try budget.check()
            try require(pid == identity.pid, "coordinate hit test lost target PID")
            hitPoints.append(p); return fixtureHit
        },
        session: { try InputSession(poster: { coordinateEvents.append(($0.type, $0.location)) }, installSignalHandlers: false) })
    func coordinateDispatch(_ action: Action, _ environment: InputEnvironment) throws -> Object {
        try performAction(action, buildTree: { () throws -> Tree in
            throw TestError(message: "coordinate action enumerated the full AX tree")
        }, semantic: { _ in throw TestError(message: "coordinate action used semantic delivery") }, pointer: {
            try input(action, identity: identity, tree: $0, budget: Budget(seconds: 1), environment: environment)
        })
    }
    let coordinateResult = try coordinateDispatch(coordinateDrag, environment)
    try require(coordinateResult["window_id"] as? Int == 7, "coordinate target lost its window constraint")
    try require(coordinateEvents.map { $0.0 } == [.leftMouseDown, .leftMouseDragged, .leftMouseDragged, .leftMouseUp],
                "coordinate drag did not dispatch the paired route")
    try require(hitPoints == [CGPoint(x: -190, y: 20), CGPoint(x: -190, y: 20)] +
                dragPoints(from: CGPoint(x: -190, y: 20), to: CGPoint(x: -10, y: 80), duration: 0.01),
                "coordinate path skipped initial or moving AX hit checks")
    try require(accessChecks == 1 && focusChecks > coordinateEvents.count && windowChecks == 5,
                "coordinate path skipped access, focus/identity or current-window checks")

    for name in ["click", "double-click", "right-click", "move", "hover", "scroll"] {
        let action = try Action(["action": name, "mode": "input", "target": ["window_id": 7],
                                 "point": ["x": -50, "y": 30]])
        _ = try coordinateDispatch(action, environment)
    }
    // Element selectors (even alongside coordinates) and non-coordinate window
    // selectors must still reach full discovery, including semantic operations.
    let discoveryRequests: [Object] = [
        ["action": "drag", "mode": "input", "target": ["identifier": "grip", "window_id": 7],
         "from": ["x": -190, "y": 20], "to": ["x": -10, "y": 80]],
        ["action": "click", "mode": "input", "target": ["id": "ax:fixture:app/w0"], "point": ["x": -50, "y": 30]],
        ["action": "click", "mode": "input", "target": ["window_id": 7]],
        ["action": "key", "mode": "input", "key": "space", "target": ["window_id": 7]],
        ["action": "focus", "mode": "accessibility", "target": ["window_id": 7]]
    ]
    for fields in discoveryRequests {
        try failure("unsupported") {
            _ = try performAction(Action(fields), buildTree: { () throws -> Tree in
                throw Failure("unsupported", "fixture full-tree marker")
            }, semantic: { _ in throw TestError(message: "semantic action skipped discovery") },
               pointer: { _ in throw TestError(message: "control selector skipped discovery") })
        }
    }

    coordinateEvents.removeAll()
    var outsideRoute = coordinateRequest
    outsideRoute["to"] = ["x": 10, "y": 80]
    try failure("assertion-failed") { _ = try coordinateDispatch(Action(outsideRoute), environment) }
    try require(coordinateEvents.isEmpty, "invalid route posted mouse-down before full-route validation")
    // Same-process occlusion along the route is rejected before pressing even
    // when the start/end points are both inside the requested owned window.
    var blocked = environment
    blocked.ownedWindows = { _ in [WindowInfo(id: 8, bounds: CGRect(x: -110, y: 40, width: 20, height: 20),
                                             title: nil, onScreen: true, layer: 0), owned] }
    try failure("assertion-failed") { _ = try coordinateDispatch(coordinateDrag, blocked) }
    try require(coordinateEvents.isEmpty, "route ignored a different frontmost owned window")
    blocked.ownedWindows = { _ in [WindowInfo(id: 8, bounds: owned.bounds, title: nil, onScreen: true, layer: 0)] }
    try failure("assertion-failed") { _ = try coordinateDispatch(coordinateDrag, blocked) }
    try require(coordinateEvents.isEmpty, "wrong CG window ownership allowed dispatch")
    blocked.ownedWindows = { _ in [WindowInfo(id: 8, bounds: owned.bounds, title: nil, onScreen: true, layer: 101), owned] }
    try failure("assertion-failed") { _ = try coordinateDispatch(coordinateDrag, blocked) }
    try require(coordinateEvents.isEmpty, "nonstandard owned overlay allowed dispatch into a pinned window")
    blocked = environment
    blocked.hit = { _, _, _ in throw Failure("assertion-failed", "fixture cross-process AX hit") }
    try failure("assertion-failed") { _ = try coordinateDispatch(coordinateDrag, blocked) }
    try require(coordinateEvents.isEmpty, "occluded coordinate action dispatched input")
    blocked = environment
    blocked.requireAccess = { throw Failure("permission-required", "fixture access denied") }
    try failure("permission-required") { _ = try coordinateDispatch(coordinateDrag, blocked) }
    try require(coordinateEvents.isEmpty, "permission denial allowed dispatch")
    for status in ["target-lost", "assertion-failed", "timed-out"] {
        blocked = environment
        blocked.validateFocus = { _, _ in throw Failure(status, "fixture identity/focus/deadline refusal") }
        try failure(status) { _ = try coordinateDispatch(coordinateDrag, blocked) }
        try require(coordinateEvents.isEmpty, "identity/focus/deadline refusal allowed dispatch")
    }
    // Fresh CG bounds and AX hit ownership are required during held input too.
    // Losing either releases the pressed button without dispatching later motion.
    for loseWindow in [true, false] {
        blocked = environment
        blocked.ownedWindows = { _ in coordinateEvents.isEmpty || !loseWindow ? [owned] : [] }
        blocked.hit = { _, _, _ in
            if !coordinateEvents.isEmpty && !loseWindow { throw Failure("assertion-failed", "fixture moving hit occluded") }
            return fixtureHit
        }
        try failure("assertion-failed") { _ = try coordinateDispatch(coordinateDrag, blocked) }
        try require(coordinateEvents.map { $0.0 } == [.leftMouseDown, .leftMouseUp],
                    "lost current bounds/hit did not stop motion and release input")
        coordinateEvents.removeAll()
    }

    let unicode = String(repeating: "x", count: 19) + "😀" + "e\u{301}" + "🦋"
    let chunks = unicodeChunks(unicode)
    try require(chunks.allSatisfy { $0.count <= 20 }, "Unicode event payload exceeded bound")
    try require(chunks.flatMap { $0 } == Array(unicode.utf16), "Unicode text was changed")
    try require(chunks.allSatisfy { chunk in
        guard let first = chunk.first, let last = chunk.last else { return false }
        return !(0xDC00...0xDFFF).contains(first) && !(0xD800...0xDBFF).contains(last)
    }, "surrogate pair was split across events")
    try require(unicodeChunks("").isEmpty, "empty text must post no keys")

    try failure("unsupported") { _ = try Action(["action": "click", "mode": "hook"]) }
    try failure("unsupported") { _ = try Action(["action": "drag", "mode": "accessibility"]) }
    try failure("unsupported") { _ = try Action(["action": "window", "mode": "input"]) }
    try failure("error") { _ = try Action(["action": "click", "mode": "input"]) }
    try failure("error") { _ = try Action(["action": "drag", "mode": "input", "from": ["x": 0, "y": 0]]) }
    try failure("error") { _ = try Action(["action": "type", "mode": "input", "text": 12]) }
    try failure("error") { _ = try Action(["action": "scroll", "mode": "input", "delta_y": true]) }
    try failure("error") { _ = try Action(["action": "key", "mode": "input", "key": "a", "modifiers": ["cmd", "command"]]) }
    try failure("unsupported") { _ = try keySpec(["key": "keycode:55"]) }
    try require(try keySpec(["key": "space"]).code == 49, "space mapping")
    try require(try keySpec(["key": "keycode:42"]).code == 42, "explicit hardware keycode mapping")
    let chord = try keySpec(["key": "return", "modifiers": ["cmd", "shift"]])
    try require(chord.flags.contains([.maskCommand, .maskShift]) && chord.modifiers == [55, 56], "key chord modifiers")

    var frontmost = false
    var identityChecks = 0
    var pumps = 0
    var pumpIntervals: [Double] = []
    try waitForActivation(budget: Budget(seconds: 1), isFrontmost: { frontmost },
                          validateIdentity: { identityChecks += 1 }, pump: { interval in
        pumpIntervals.append(interval)
        pumps += 1; frontmost = true
    })
    try require(pumps == 1 && identityChecks == 2, "activation must refresh a stale snapshot and revalidate identity")
    try require(pumpIntervals.allSatisfy { $0 > 0 && $0 <= 0.02 }, "activation pump exceeded its bound")
    try failure("target-lost") {
        try waitForActivation(budget: Budget(seconds: 1), isFrontmost: { true },
                              validateIdentity: { throw Failure("target-lost", "fixture PID changed") },
                              pump: { _ in pumps += 1 })
    }
    try failure("timed-out") {
        try waitForActivation(budget: Budget(seconds: 0), isFrontmost: { true },
                              validateIdentity: { identityChecks += 1 }, pump: { _ in pumps += 1 })
    }
    try require(pumps == 1 && identityChecks == 2, "expired activation or identity loss must not pump or dispatch")

    // These CGEvents go exclusively to this in-memory sink, including cleanup.
    var events: [(CGEventType, Int64)] = []
    let session = try InputSession(poster: { events.append(($0.type, $0.getIntegerValueField(.keyboardEventKeycode))) }, installSignalHandlers: false)
    let commandUp = try session.keyboard(55, down: false)
    try session.post(session.keyboard(55, down: true), release: commandUp)
    let aUp = try session.keyboard(0, down: false)
    try session.post(session.keyboard(0, down: true), release: aUp)
    session.releaseAll()
    try require(events.map { $0.1 } == [55, 0, 0, 55], "cleanup must release keys in reverse order")
    // Quartz represents modifier transitions as flagsChanged, including release.
    try require(events.map { $0.0 } == [.flagsChanged, .keyDown, .keyUp, .flagsChanged], "cleanup must use key up/modifier release events")
    session.releaseAll()
    try require(events.count == 4 && session.releases.isEmpty, "cleanup must be idempotent")
    try session.post(session.keyboard(0, down: true), release: aUp)
    session.cancelled = true; session.releaseAll()
    try failure("error") { try session.post(session.keyboard(0, down: true), release: aUp) }
    try require(events.count == 6 && session.releases.isEmpty, "cancelled session must release and refuse further down events")
    var pointerEvents: [(CGEventType, CGPoint)] = []
    let mouse = try InputSession(poster: {
        events.append(($0.type, 0)); pointerEvents.append(($0.type, $0.location))
    }, installSignalHandlers: false)
    let mouseUp = try mouse.mouse(.leftMouseUp, at: CGPoint(x: -50, y: 20))
    try mouse.post(mouse.mouse(.leftMouseDown, at: CGPoint(x: -50, y: 20)), release: mouseUp)
    let dragEnd = CGPoint(x: -30, y: 30)
    try mouse.post(mouse.mouse(.leftMouseDragged, at: dragEnd), releaseLocation: dragEnd)
    mouse.releaseAll()
    try require(pointerEvents.map { $0.0 } == [.leftMouseDown, .leftMouseDragged, .leftMouseUp], "mouse cancellation must post release")
    try require(pointerEvents.last?.1 == dragEnd, "drag cleanup must release at the last dispatched location")
    try failure("error") {
        try mouse.post(mouse.mouse(.leftMouseDragged, at: dragEnd), releaseLocation: dragEnd)
    }
    try require(pointerEvents.count == 3, "missing cleanup must be rejected before pointer motion")
    print("native core fixture and injected-input checks passed")
}
