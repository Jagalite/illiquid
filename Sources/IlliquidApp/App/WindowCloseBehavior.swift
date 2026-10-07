import Foundation

enum WindowCloseBehavior {
    static let keepsRunningKey = "Illiquid.keeps-running-after-last-window-closed"

    static func shouldTerminate(keepsRunning: Bool, pictureInPictureActive: Bool) -> Bool {
        !keepsRunning && !pictureInPictureActive
    }
}
