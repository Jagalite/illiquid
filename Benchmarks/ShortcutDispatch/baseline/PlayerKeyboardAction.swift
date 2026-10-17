import Foundation
import AppKit

enum PlayerKeyboardAction: Equatable {
    case togglePause
    case seek(TimeInterval)
    case volume(Double)
    case stepFrame(Int)
    case chapter(Int)
    case undoSeek
    case dismiss
    case showShortcuts
    case showInspector
    case toggleFullscreen
    case toggleMute
    case goToTime
    case loopA
    case loopB
    case clearABLoop
    case screenshot

    static func resolve(
        keyCode: UInt16,
        characters: String? = nil,
        modifierFlags: NSEvent.ModifierFlags,
        isRepeat: Bool
    ) -> Self? {
        var modifiers = modifierFlags.intersection(.deviceIndependentFlagsMask)
        modifiers.subtract([.capsLock, .function, .numericPad])

        // Letter/symbol shortcuts follow the active layout, matching the text
        // printed in Help. Navigation keys remain independent of layout.
        if !isRepeat {
            if characters == "?", modifiers.isSubset(of: [.shift, .option]) {
                return .showShortcuts
            }
            if modifiers.isEmpty {
                switch characters?.lowercased() {
                case "i": return .showInspector
                case "f": return .toggleFullscreen
                case "m": return .toggleMute
                default: break
                }
            }
        }

        switch keyCode {
        case 49 where modifiers.isEmpty && !isRepeat:
            return .togglePause
        case 123 where modifiers.isEmpty:
            return .seek(-5)
        case 124 where modifiers.isEmpty:
            return .seek(5)
        case 123 where modifiers == .shift:
            return .seek(-1)
        case 124 where modifiers == .shift:
            return .seek(1)
        case 123 where modifiers == .option:
            return .stepFrame(-1)
        case 124 where modifiers == .option:
            return .stepFrame(1)
        case 126 where modifiers.isEmpty:
            return .volume(5)
        case 125 where modifiers.isEmpty:
            return .volume(-5)
        case 126 where modifiers == .option:
            return .volume(1)
        case 125 where modifiers == .option:
            return .volume(-1)
        case 116 where modifiers.isEmpty && !isRepeat:
            return .chapter(-1)
        case 121 where modifiers.isEmpty && !isRepeat:
            return .chapter(1)
        case 116 where modifiers == .shift:
            return .seek(-600)
        case 121 where modifiers == .shift:
            return .seek(600)
        case 51 where modifiers == .shift && !isRepeat:
            return .undoSeek
        case 53 where modifiers.isEmpty && !isRepeat:
            return .dismiss
        default:
            return nil
        }
    }
}
