import AppKit
import Testing
@testable import SuperplayrApp

@Suite("Window close behavior")
@MainActor
struct WindowCloseBehaviorTests {
    @Test(arguments: [false, true], [false, true])
    func pictureInPictureAndPreferenceDetermineLastWindowPolicy(keep: Bool, pip: Bool) {
        #expect(WindowCloseBehavior.shouldTerminate(keepsRunning: keep, pictureInPictureActive: pip)
                == (!keep && !pip))
    }

    @Test func preferenceDefaultsOffAndDelegateReadsChangesWithoutRelaunch() throws {
        let suite = "WindowCloseBehaviorTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let delegate = AppDelegate(shutdown: { nil }, keepsRunningAfterLastWindowClosed: {
            defaults.bool(forKey: WindowCloseBehavior.keepsRunningKey)
        })
        #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
        defaults.set(true, forKey: WindowCloseBehavior.keepsRunningKey)
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
        defaults.set(false, forKey: WindowCloseBehavior.keepsRunningKey)
        #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
    }

    @Test func explicitQuitStillFinishesWhenKeepRunningIsEnabled() async {
        var stopped = false
        var replied = false
        let delegate = AppDelegate(shutdown: { stopped = true; return nil },
                                   keepsRunningAfterLastWindowClosed: { true })
        await delegate.finishTermination { replied = true }
        #expect(stopped && replied)
        #expect(delegate.applicationShouldTerminate(.shared) == .terminateNow)
    }
}
