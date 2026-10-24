// Compiled by Scripts/tests/subtitle-delay-dialog-tests.py through Kyoto.
// The production callback, parser, shortcuts, and MediaSource are used verbatim.
// Only UI presentation and player side effects are replaced; no AppKit input.
import Foundation
import CoreGraphics

// The fake UI uses CoreGraphics geometry without the AppKit NSRect overlay.
typealias NSRect = CGRect

// PRODUCTION_PARSER

@MainActor final class NSTextField {
    var placeholderString: String?
    var stringValue = ""
    init(frame: NSRect) {}
}

enum Response: Sendable { case alertFirstButtonReturn, alertSecondButtonReturn }

@MainActor final class NSAlert {
    static var presented: [NSAlert] = []
    var messageText = ""
    var informativeText = ""
    var accessoryView: NSTextField?
    let window = Window()
    var completion: ((Response) -> Void)?
    func addButton(withTitle: String) {}
    func beginSheetModal(for: Window, completionHandler: @escaping (Response) -> Void) {
        completion = completionHandler
        Self.presented.append(self)
    }
    func respond(_ response: Response, text: String) async {
        accessoryView!.stringValue = text
        let transitions = DialogModel.transitions
        completion!(response)
        await Self.awaitCallback(after: transitions)
    }
    static func awaitCallback(after transitions: Int) async {
        // Observe callback completion rather than assuming MainActor task ordering.
        for _ in 0..<1_000 {
            if DialogModel.transitions > transitions { return }
            await Task.yield()
        }
        preconditionFailure("production callback did not settle")
    }
}

@MainActor final class Window { var initialFirstResponder: NSTextField? }

@MainActor final class DialogModel {
    static var transitions = 0
    struct State { var currentSource: MediaSource? }
    var state: State
    var playerWindow: Window? = Window()
    var isShuttingDown = false
    var transient = false
    var applied: [TimeInterval] = []
    init(source: MediaSource?) { state = State(currentSource: source) }
    func open() { presentSubtitleDelayPanel(inputText: "0", validationMessage: nil) }
    func setTransientPresentation(_ value: Bool, owner: String) {
        precondition(owner == "subtitle-delay")
        transient = value
        Self.transitions += 1
    }
    func setSubtitleDelayFromUser(_ value: TimeInterval) { applied.append(value) }
    // PRODUCTION_CALLBACK
}

enum Help {
    // PRODUCTION_SHORTCUTS
}

@main struct DialogTests {
    @MainActor static func main() async {
        let original = MediaSource.localFile(URL(fileURLWithPath: "/fixture/original.mp4"))
        let replacement = MediaSource.localFile(URL(fileURLWithPath: "/fixture/replacement.mp4"))
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }

        // Accept the same whole-millisecond input, including both exact bounds.
        for (text, seconds) in [("-10000", -10.0), ("10000", 10.0),
                                (" +200 ", 0.2), ("-1250", -1.25), ("0", 0.0)] {
            let model = DialogModel(source: original)
            model.open()
            await NSAlert.presented.last!.respond(.alertFirstButtonReturn, text: text)
            check(model.applied == [seconds], "valid delay was not applied: \(text)")
            check(!model.transient, "successful submission retained transient state")
        }

        // Invalid text reopens validation, preserving input and transient state.
        for text in ["-10001", "10001", "1.5", "later", "", "999999999999999999999999"] {
            let model = DialogModel(source: original)
            model.open()
            let count = NSAlert.presented.count
            await NSAlert.presented.last!.respond(.alertFirstButtonReturn, text: text)
            check(model.applied.isEmpty, "invalid input mutated delay")
            check(NSAlert.presented.count == count + 1, "validation did not reopen")
            check(NSAlert.presented.last!.accessoryView!.stringValue == text,
                  "validation discarded input")
            check(model.transient, "validation lost transient state")
            await NSAlert.presented.last!.respond(.alertSecondButtonReturn, text: text)
            check(!model.transient && model.applied.isEmpty, "cancel did not clean up")
        }

        // Source replacement/closure rejects both valid and invalid text before retry.
        for changedSource in [replacement, nil] as [MediaSource?] {
            for text in ["500", "invalid"] {
                let model = DialogModel(source: original)
                model.open()
                let count = NSAlert.presented.count
                model.state.currentSource = changedSource
                await NSAlert.presented.last!.respond(.alertFirstButtonReturn, text: text)
                check(model.applied.isEmpty, "stale dialog changed replacement source")
                check(NSAlert.presented.count == count, "stale dialog reopened validation")
                check(!model.transient, "stale dialog retained transient state")
            }
        }

        // The source captured by a validation retry also remains guarded.
        let retry = DialogModel(source: original)
        retry.open()
        await NSAlert.presented.last!.respond(.alertFirstButtonReturn, text: "1.5")
        retry.state.currentSource = replacement
        await NSAlert.presented.last!.respond(.alertFirstButtonReturn, text: "750")
        check(retry.applied.isEmpty && !retry.transient, "retry bypassed source identity")

        let shutdown = DialogModel(source: original)
        shutdown.open()
        shutdown.isShuttingDown = true
        await NSAlert.presented.last!.respond(.alertFirstButtonReturn, text: "500")
        check(shutdown.applied.isEmpty && !shutdown.transient, "shutdown applied delay")

        let cancelled = DialogModel(source: original)
        cancelled.open()
        await NSAlert.presented.last!.respond(.alertSecondButtonReturn, text: "500")
        check(cancelled.applied.isEmpty && !cancelled.transient, "cancel applied delay")

        // A source change between the AppKit completion and MainActor task is stale.
        let deferred = DialogModel(source: original)
        deferred.open()
        let transitions = DialogModel.transitions
        NSAlert.presented.last!.completion!(.alertFirstButtonReturn)
        deferred.state.currentSource = replacement
        await NSAlert.awaitCallback(after: transitions)
        check(deferred.applied.isEmpty && !deferred.transient, "queued callback bypassed guard")

        for frames in [false, true] {
            for pip in [false, true] {
                let commandT = Help.shortcuts(supportsFrameStep: frames,
                                             supportsPictureInPicture: pip)
                    .filter { $0.0 == "Command-T" }
                check(commandT.count == 1 && commandT.first?.1 == "New Video Tab",
                      "Command-T help disagrees with New Video Tab command")
            }
        }
        print("\(checks) production dialog/help checks passed; fake UI, live UI UNRUN")
    }
}
