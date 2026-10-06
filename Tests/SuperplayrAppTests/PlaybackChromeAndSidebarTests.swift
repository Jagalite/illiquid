import AppKit
import CoreGraphics
import Foundation
import SuperplayrPlayback
import SuperplayrPlayer
import SwiftUI
import Testing
@testable import SuperplayrApp

@Suite("Player themes")
@MainActor
struct PlayerThemeTests {
    @Test func settingsExposeSevenStableDestinations() {
        #expect(SettingsDestination.allCases == [
            .playback,
            .behavior,
            .audio,
            .video,
            .appearance,
            .sources,
            .data,
        ])
        #expect(Set(SettingsDestination.allCases.map(\.title)).count == 7)
        #expect(Set(SettingsDestination.allCases.map(\.systemImage)).count == 7)
    }

    @Test func exposesFiveStableThemeChoices() {
        #expect(PlayerTheme.allCases == [
            .liquidGlass,
            .graphite,
            .midnight,
            .nord,
            .classic,
        ])
        #expect(Set(PlayerTheme.allCases.map(\.rawValue)).count == 5)
    }

    @Test func selectionDefaultsToLiquidGlassAndPersists() throws {
        let suiteName = "PlayerThemeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PlayerThemeStore(defaults: defaults)
        #expect(store.selection == .liquidGlass)

        store.select(.nord)

        #expect(PlayerThemeStore(defaults: defaults).selection == .nord)
        #expect(
            defaults.string(forKey: PlayerThemeStore.storageKey)
                == PlayerTheme.nord.rawValue
        )
    }

    @Test func invalidSavedSelectionFallsBackToLiquidGlass() throws {
        let suiteName = "PlayerThemeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("missing-theme", forKey: PlayerThemeStore.storageKey)

        #expect(PlayerThemeStore(defaults: defaults).selection == .liquidGlass)
    }

    @Test func textColorModeDefaultsToRainbowAndPersistsAllChoices() throws {
        let suiteName = "PlayerThemeTextColorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PlayerThemeStore(defaults: defaults)
        #expect(store.textColorMode == .dynamicRainbow)
        #expect(PlayerTextColorMode.allCases == [
            .dynamicRainbow,
            .dynamicMonochrome,
            .staticColor,
        ])

        store.selectTextColorMode(.dynamicMonochrome)
        #expect(
            PlayerThemeStore(defaults: defaults).textColorMode
                == .dynamicMonochrome
        )

        store.selectTextColorMode(.staticColor)
        #expect(PlayerThemeStore(defaults: defaults).textColorMode == .staticColor)
        #expect(
            defaults.string(forKey: PlayerThemeStore.textColorModeStorageKey)
                == PlayerTextColorMode.staticColor.rawValue
        )
    }

    @Test func rainbowPaletteDefaultsToSoftSpectrumAndPersistsAllChoices() throws {
        let suiteName = "PlayerThemeRainbowPaletteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PlayerThemeStore(defaults: defaults)
        #expect(store.rainbowPalette == .softSpectrum)
        #expect(PlayerRainbowPalette.allCases == [
            .softSpectrum,
            .balanced,
            .analogous,
            .complementary,
            .warm,
            .cool,
        ])

        for palette in PlayerRainbowPalette.allCases {
            store.selectRainbowPalette(palette)
            #expect(
                PlayerThemeStore(defaults: defaults).rainbowPalette == palette
            )
        }
        #expect(
            defaults.string(forKey: PlayerThemeStore.rainbowPaletteStorageKey)
                == PlayerRainbowPalette.cool.rawValue
        )

        defaults.set(
            "missing-palette",
            forKey: PlayerThemeStore.rainbowPaletteStorageKey
        )
        #expect(PlayerThemeStore(defaults: defaults).rainbowPalette == .softSpectrum)
    }

    @Test func samplesOnlyForDynamicLiquidGlassText() throws {
        let suiteName = "PlayerThemeSamplingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PlayerThemeStore(defaults: defaults)

        #expect(store.usesVideoColorSampling)
        store.selectTextColorMode(.staticColor)
        #expect(!store.usesVideoColorSampling)
        store.selectTextColorMode(.dynamicMonochrome)
        #expect(store.usesVideoColorSampling)
        store.select(.graphite)
        #expect(!store.usesVideoColorSampling)
    }
}

@Suite("Benchmark playback control")
@MainActor
struct BenchmarkPlaybackControlTests {
    @Test func configurationRequiresBenchmarkBundleOverrideSessionAndAbsolutePath() {
        let enabled = [
            "SUPERPLAYR_ENABLE_BENCHMARK_OVERRIDES": "1",
            "SUPERPLAYR_BENCHMARK_CONTROL_SESSION": "run-1",
            "SUPERPLAYR_BENCHMARK_CONTROL_FILE": "/private/tmp/run-1.json",
        ]
        #expect(BenchmarkPlaybackControl.configuration(
            environment: enabled,
            bundleIdentifier: "com.example.SuperplayrBenchmark"
        ) == .init(
            session: "run-1",
            commandFileURL: URL(fileURLWithPath: "/private/tmp/run-1.json")
        ))
        #expect(BenchmarkPlaybackControl.configuration(
            environment: enabled,
            bundleIdentifier: "com.example.Superplayr"
        ) == nil)
        #expect(BenchmarkPlaybackControl.configuration(
            environment: enabled.merging([
                "SUPERPLAYR_BENCHMARK_CONTROL_FILE": "relative.json"
            ]) { _, new in new },
            bundleIdentifier: "com.example.SuperplayrBenchmark"
        ) == nil)
        #expect(BenchmarkPlaybackControl.configuration(
            environment: enabled.merging([
                "SUPERPLAYR_BENCHMARK_CONTROL_SESSION": "invalid session"
            ]) { _, new in new },
            bundleIdentifier: "com.example.SuperplayrBenchmark"
        ) == nil)
        #expect(BenchmarkPlaybackControl.isValidToken("seek-42"))
        #expect(!BenchmarkPlaybackControl.isValidToken("seek 42"))
        #expect(!BenchmarkPlaybackControl.isValidToken(String(repeating: "x", count: 97)))
    }

    @Test func commandDecoderMapsOnlyExplicitActions() throws {
        let seek = try JSONDecoder().decode(
            BenchmarkPlaybackControlCommand.self,
            from: Data("""
                {"session":"run-1","id":"seek-7","action":"seek-exact","targetSeconds":42.5}
                """.utf8)
        )
        #expect(seek.playbackAction == .seekExact(42.5))

        let unknown = try JSONDecoder().decode(
            BenchmarkPlaybackControlCommand.self,
            from: Data("""
                {"session":"run-1","id":"bad-1","action":"delete","targetSeconds":null}
                """.utf8)
        )
        #expect(unknown.playbackAction == nil)
    }

    @Test func commandDeduplicationIsBoundedAndAllowsEvictedIDsAgain() {
        var deduplicator = BenchmarkPlaybackControlDeduplicator(capacity: 2)
        let first = deduplicator.accepts(session: "run-1", id: "one")
        let duplicate = deduplicator.accepts(session: "run-1", id: "one")
        let second = deduplicator.accepts(session: "run-1", id: "two")
        let third = deduplicator.accepts(session: "run-1", id: "three")
        let evicted = deduplicator.accepts(session: "run-1", id: "one")
        let otherSession = deduplicator.accepts(session: "run-2", id: "one")

        #expect(first)
        #expect(!duplicate)
        #expect(second)
        #expect(third)
        #expect(evicted)
        #expect(otherSession)
    }
}

@Suite("Benchmark playback chrome")
@MainActor
struct BenchmarkPlaybackChromeTests {
    @Test func pinningRequiresBenchmarkBundleAndExplicitOverrides() {
        let enabled = [
            "SUPERPLAYR_ENABLE_BENCHMARK_OVERRIDES": "1",
            "SUPERPLAYR_BENCHMARK_PIN_PLAYBACK_CHROME": "1",
        ]

        #expect(AppModel.benchmarkPinsPlaybackChrome(
            environment: enabled,
            bundleIdentifier: "com.example.SuperplayrBenchmark"
        ))
        #expect(!AppModel.benchmarkPinsPlaybackChrome(
            environment: enabled,
            bundleIdentifier: "com.example.Superplayr"
        ))
        #expect(!AppModel.benchmarkPinsPlaybackChrome(
            environment: enabled.merging([
                "SUPERPLAYR_ENABLE_BENCHMARK_OVERRIDES": "0"
            ]) { _, new in new },
            bundleIdentifier: "com.example.SuperplayrBenchmark"
        ))

        let hiddenSidebar = enabled.merging([
            "SUPERPLAYR_BENCHMARK_HIDE_SIDEBAR": "1"
        ]) { _, new in new }
        #expect(AppModel.benchmarkHidesSidebar(
            environment: hiddenSidebar,
            bundleIdentifier: "com.example.SuperplayrBenchmark"
        ))
        #expect(!AppModel.benchmarkHidesSidebar(
            environment: hiddenSidebar,
            bundleIdentifier: "com.example.Superplayr"
        ))
    }
}

@Suite("Playback timeline slider")
@MainActor
struct PlaybackTimelineSliderTests {
    @Test func passiveProgressMovesWithoutPublishingThroughTheBackingCell() {
        let fixture = TimelineSliderFixture()

        fixture.slider.setPassiveValue(42)

        #expect(fixture.slider.passiveValue == 42)
        #expect(fixture.slider.doubleValue == 42)
        #expect(fixture.slider.presentationMode == .passive)
        #expect((fixture.slider.accessibilityValue() as? NSNumber)?.doubleValue == 42)

        fixture.window.contentView?.layoutSubtreeIfNeeded()
        fixture.slider.layoutSubtreeIfNeeded()
        fixture.slider.setPassiveValue(43)

        #expect(fixture.window.contentView?.needsLayout == false)
        #expect(fixture.slider.needsLayout == false)
    }

    @Test func unchangedPositionRestoresPassivePresentationAfterInvalidation() {
        let fixture = TimelineSliderFixture()

        fixture.slider.setPassiveValue(42)
        fixture.slider.viewDidChangeEffectiveAppearance()

        #expect(fixture.slider.passiveValue == 42)
        #expect(fixture.slider.doubleValue == 42)
        #expect(fixture.slider.presentationMode == .native)

        fixture.slider.setPassiveValue(42)

        #expect(fixture.slider.presentationMode == .passive)
        #expect(fixture.slider.passiveValue == 42)
        #expect(fixture.slider.doubleValue == 42)
    }

    @Test func invalidationRevealsReplacementNativeHost() {
        let fixture = TimelineSliderFixture()
        fixture.slider.setPassiveValue(42)

        var originalHost: NSView? = fixture.slider.subviews.first
        originalHost?.removeFromSuperview()
        originalHost = nil

        let replacementHost = NSView(frame: fixture.slider.bounds)
        replacementHost.isHidden = true
        fixture.slider.addSubview(
            replacementHost,
            positioned: .below,
            relativeTo: fixture.slider.subviews.first
        )

        fixture.slider.setFrameSize(NSSize(width: 438, height: 28))

        #expect(!replacementHost.isHidden)
        #expect(replacementHost.needsDisplay)
        #expect(fixture.slider.presentationMode == .native)
        #expect(fixture.slider.doubleValue == 42)
    }

    @Test func focusTransitionsOwnNativeAndPassivePresentation() throws {
        let fixture = TimelineSliderFixture()
        fixture.slider.setPassiveValue(42)

        #expect(fixture.slider.presentationMode == .passive)
        try #require(fixture.window.makeFirstResponder(fixture.slider))

        #expect(fixture.slider.presentationMode == .native)
        #expect(fixture.slider.doubleValue == 42)

        try #require(fixture.window.makeFirstResponder(nil))

        #expect(fixture.slider.presentationMode == .passive)
        #expect(fixture.slider.passiveValue == 42)
        #expect(fixture.slider.doubleValue == 42)
    }

    @Test func repeatedPassiveTimelineWidthChangesStayLayoutSafe() {
        let fixture = TimelineSliderFixture()
        fixture.slider.setPassiveValue(42)

        for width in stride(from: 440.0, through: 220.0, by: -2.0) {
            fixture.slider.setFrameSize(
                NSSize(width: width, height: fixture.slider.bounds.height)
            )
            fixture.window.contentView?.layoutSubtreeIfNeeded()
        }
        for width in stride(from: 220.0, through: 440.0, by: 2.0) {
            fixture.slider.setFrameSize(
                NSSize(width: width, height: fixture.slider.bounds.height)
            )
            fixture.window.contentView?.layoutSubtreeIfNeeded()
        }

        #expect(fixture.slider.passiveValue == 42)
        #expect(fixture.slider.doubleValue == 42)
        #expect(fixture.slider.presentationMode == .native)
        #expect(fixture.window.contentView?.needsLayout == false)

        fixture.slider.setPassiveValue(42)

        #expect(fixture.slider.presentationMode == .passive)
        #expect(fixture.slider.doubleValue == 42)
    }

    @Test func revealingNativeSliderAfterPassivePresentationKeepsPartialFill() throws {
        let fixture = TimelineSliderFixture()
        fixture.slider.setPassiveValue(42)
        fixture.slider.viewDidChangeEffectiveAppearance()

        let nativeWindow = TimelineSliderFixture.makeWindow()
        let native = NSSlider(
            value: 42,
            minValue: 0,
            maxValue: 100,
            target: nil,
            action: nil
        )
        native.trackFillColor = PlaybackTimelineStyle.progressColor
        native.frame = fixture.slider.frame
        nativeWindow.contentView?.addSubview(native)
        nativeWindow.contentView?.layoutSubtreeIfNeeded()
        native.layoutSubtreeIfNeeded()

        let revealedImage = try #require(TimelineSliderFixture.snapshot(fixture.slider))
        let nativeImage = try #require(TimelineSliderFixture.snapshot(native))
        let difference = try meanAbsoluteComponentDifference(
            revealedImage,
            nativeImage
        )

        #expect(difference < 0.01)
    }

    @Test func timelineUsesSilverProgressColor() {
        let fixture = TimelineSliderFixture()

        #expect(
            fixture.slider.trackFillColor
                == PlaybackTimelineStyle.progressColor
        )
    }

    @Test func accessibilityValueChangesSynchronizeTheInteractiveSlider() {
        let recorder = TimelineSliderActionRecorder()
        let fixture = TimelineSliderFixture(target: recorder)

        fixture.slider.setPassiveValue(42)
        fixture.slider.setAccessibilityValue(NSNumber(value: 63))

        #expect(fixture.slider.passiveValue == 63)
        #expect(fixture.slider.doubleValue == 63)
        #expect(fixture.slider.presentationMode == .passive)
        #expect(recorder.values == [63])
    }

    @Test func accessibilityStepsSynchronizeAndDispatchExactValues() {
        let recorder = TimelineSliderActionRecorder()
        let fixture = TimelineSliderFixture(target: recorder)
        fixture.slider.setPassiveValue(42)

        _ = fixture.slider.accessibilityPerformIncrement()
        _ = fixture.slider.accessibilityPerformDecrement()

        #expect(fixture.slider.passiveValue == 42)
        #expect(fixture.slider.doubleValue == 42)
        #expect(fixture.slider.presentationMode == .passive)
        #expect(recorder.values == [47, 42])
    }

    @Test func keyboardStepsSynchronizeAndDispatchExactValues() throws {
        let recorder = TimelineSliderActionRecorder()
        let fixture = TimelineSliderFixture(target: recorder)
        fixture.slider.setPassiveValue(42)
        try #require(fixture.window.makeFirstResponder(fixture.slider))
        let rightArrow = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: fixture.window.windowNumber,
            context: nil,
            characters: String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)),
            charactersIgnoringModifiers: String(
                Character(UnicodeScalar(NSRightArrowFunctionKey)!)
            ),
            isARepeat: false,
            keyCode: 124
        ))

        fixture.slider.keyDown(with: rightArrow)

        #expect(fixture.slider.passiveValue == 47)
        #expect(fixture.slider.doubleValue == 47)
        #expect(fixture.slider.presentationMode == .native)
        #expect(recorder.values == [47])
    }

    @Test func detachedPassivePresentationMatchesTheNativeSlider() throws {
        let passive = TimelineSliderFixture()
        passive.slider.setPassiveValue(42)

        #expect(passive.slider.presentationMode == .passive)

        let nativeWindow = TimelineSliderFixture.makeWindow()
        let native = NSSlider(
            value: 42,
            minValue: 0,
            maxValue: 100,
            target: nil,
            action: nil
        )
        native.trackFillColor = PlaybackTimelineStyle.progressColor
        native.frame = passive.slider.frame
        nativeWindow.contentView?.addSubview(native)
        nativeWindow.contentView?.layoutSubtreeIfNeeded()
        native.layoutSubtreeIfNeeded()

        let passiveImage = try #require(TimelineSliderFixture.snapshot(passive.slider))
        let nativeImage = try #require(TimelineSliderFixture.snapshot(native))
        let difference = try meanAbsoluteComponentDifference(
            passiveImage,
            nativeImage
        )

        #expect(difference < 0.01)
    }
}

@MainActor
private final class TimelineSliderFixture {
    let window: NSWindow
    let slider: TrackingNSSlider

    init(target: TimelineSliderActionRecorder? = nil) {
        window = Self.makeWindow()
        slider = TrackingNSSlider(
            value: 0,
            minValue: 0,
            maxValue: 100,
            target: target,
            action: target == nil ? nil : #selector(TimelineSliderActionRecorder.changed(_:))
        )
        slider.frame = NSRect(x: 20, y: 20, width: 440, height: 28)
        window.contentView?.addSubview(slider)
        window.contentView?.layoutSubtreeIfNeeded()
        slider.layoutSubtreeIfNeeded()
    }

    static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 80),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        return window
    }

    static func snapshot(_ view: NSView) -> NSBitmapImageRep? {
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: image)
        return image
    }
}

@MainActor
private final class TimelineSliderActionRecorder: NSObject {
    private(set) var values: [Double] = []

    @objc
    func changed(_ sender: NSSlider) {
        values.append(sender.doubleValue)
    }
}

private func meanAbsoluteComponentDifference(
    _ lhs: NSBitmapImageRep,
    _ rhs: NSBitmapImageRep
) throws -> Double {
    let lhsData = try #require(lhs.bitmapData)
    let rhsData = try #require(rhs.bitmapData)
    try #require(lhs.pixelsWide == rhs.pixelsWide)
    try #require(lhs.pixelsHigh == rhs.pixelsHigh)
    try #require(lhs.bytesPerRow == rhs.bytesPerRow)

    let byteCount = lhs.bytesPerRow * lhs.pixelsHigh
    var difference = 0
    for index in 0 ..< byteCount {
        difference += abs(Int(lhsData[index]) - Int(rhsData[index]))
    }
    return Double(difference) / Double(byteCount * 255)
}

@Suite("Player keyboard shortcuts")
struct PlayerKeyboardShortcutTests {
    @Test @MainActor func shortcutHelpDescribesOnlySupportedOptionalActions() {
        let baseline = ShortcutHelpView.shortcuts(supportsFrameStep: false, supportsPictureInPicture: false)
        #expect(!baseline.contains { $0.0 == "Option-← / Option-→" })
        #expect(!baseline.contains { $0.0 == "Command-Shift-M" })
        #expect(baseline.contains { $0.0 == "Command-O" })
        let expanded = ShortcutHelpView.shortcuts(supportsFrameStep: true, supportsPictureInPicture: true)
        #expect(expanded.contains { $0.0 == "Option-← / Option-→" })
        #expect(expanded.contains { $0.0 == "Command-Shift-M" })
    }

    @Test func mapsPlaybackKeysWithoutModifiers() {
        #expect(PlayerKeyboardAction.resolve(
            keyCode: 49,
            modifierFlags: [],
            isRepeat: false
        ) == .togglePause)
        #expect(PlayerKeyboardAction.resolve(
            keyCode: 123,
            modifierFlags: [],
            isRepeat: false
        ) == .seek(-5))
        #expect(PlayerKeyboardAction.resolve(
            keyCode: 124,
            modifierFlags: [],
            isRepeat: false
        ) == .seek(5))
    }

    @Test func keepsArrowRepeatButRejectsSpaceRepeatAndModifiedKeys() {
        #expect(PlayerKeyboardAction.resolve(
            keyCode: 49,
            modifierFlags: [],
            isRepeat: true
        ) == nil)
        #expect(PlayerKeyboardAction.resolve(
            keyCode: 123,
            modifierFlags: [],
            isRepeat: true
        ) == .seek(-5))
        #expect(PlayerKeyboardAction.resolve(
            keyCode: 124,
            modifierFlags: .command,
            isRepeat: false
        ) == nil)
    }

    @Test func spaceResumeAloneRequestsImmediateChromeHide() {
        #expect(PlayerKeyboardChromePolicy.shouldHideImmediately(
            action: .togglePause,
            isPauseDesired: true
        ))
        #expect(!PlayerKeyboardChromePolicy.shouldHideImmediately(
            action: .togglePause,
            isPauseDesired: false
        ))
        #expect(!PlayerKeyboardChromePolicy.shouldHideImmediately(
            action: .seek(5),
            isPauseDesired: true
        ))
    }

    @Test func playbackButtonHidesOnlyWhenResuming() {
        #expect(PlaybackToggleChromePolicy.pointerRevealCooldown == 0.25)
        #expect(PlaybackToggleChromePolicy.shouldHideAfterActivation(
            isPauseDesired: true
        ))
        #expect(!PlaybackToggleChromePolicy.shouldHideAfterActivation(
            isPauseDesired: false
        ))
    }

    @Test func arrowSeekDoesNotRevealHiddenPlaybackChrome() {
        #expect(!PlayerKeyboardChromePolicy.shouldRegisterActivity(
            action: .seek(5),
            areControlsVisible: false
        ))
        #expect(PlayerKeyboardChromePolicy.shouldRegisterActivity(
            action: .seek(5),
            areControlsVisible: true
        ))
        #expect(PlayerKeyboardChromePolicy.shouldRegisterActivity(
            action: .volume(5),
            areControlsVisible: false
        ))
    }

    @Test func mapsFineSeekVolumeChapterAndWindowShortcuts() {
        #expect(PlayerKeyboardAction.resolve(
            keyCode: 123,
            modifierFlags: .shift,
            isRepeat: false
        ) == .seek(-1))
        #expect(PlayerKeyboardAction.resolve(
            keyCode: 124,
            modifierFlags: .option,
            isRepeat: false
        ) == .stepFrame(1))
        #expect(PlayerKeyboardAction.resolve(
            keyCode: 126,
            modifierFlags: [],
            isRepeat: false
        ) == .volume(5))
        #expect(PlayerKeyboardAction.resolve(
            keyCode: 125,
            modifierFlags: .option,
            isRepeat: false
        ) == .volume(-1))
        #expect(PlayerKeyboardAction.resolve(
            keyCode: 116,
            modifierFlags: [],
            isRepeat: false
        ) == .chapter(-1))
        #expect(PlayerKeyboardAction.resolve(
            keyCode: 121,
            modifierFlags: .shift,
            isRepeat: false
        ) == .seek(600))
        #expect(PlayerKeyboardAction.resolve(
            keyCode: 51,
            modifierFlags: .shift,
            isRepeat: false
        ) == .undoSeek)
        #expect(PlayerKeyboardAction.resolve(
            keyCode: 53,
            modifierFlags: [],
            isRepeat: false
        ) == .dismiss)
        #expect(PlayerKeyboardAction.resolve(
            keyCode: 44,
            characters: "?",
            modifierFlags: .shift,
            isRepeat: false
        ) == .showShortcuts)
        #expect(PlayerKeyboardAction.resolve(
            keyCode: 34,
            characters: "i",
            modifierFlags: [],
            isRepeat: false
        ) == .showInspector)
        #expect(PlayerKeyboardAction.resolve(
            keyCode: 3,
            characters: "f",
            modifierFlags: [],
            isRepeat: false
        ) == .toggleFullscreen)
        #expect(PlayerKeyboardAction.resolve(
            keyCode: 46,
            characters: "m",
            modifierFlags: [],
            isRepeat: false
        ) == .toggleMute)
    }

    @Test @MainActor func voiceOverNavigationCannotAlsoTriggerPlayerShortcuts() {
        let actions: [PlayerKeyboardAction] = [
            .seek(5), .volume(5), .togglePause, .toggleMute, .stepFrame(1),
            .chapter(1), .undoSeek, .dismiss, .showShortcuts, .showInspector,
            .toggleFullscreen,
        ]
        for action in actions {
            for visible in [true, false] {
                #expect(PlayerKeyboardRouting.shouldDefer(
                    action: action, firstResponder: nil,
                    isPlaybackChromeVisible: visible, isVoiceOverEnabled: true))
            }
        }
    }

    @Test @MainActor func focusedNativeControlsKeepNonGlobalKeyboardEvents() {
        let slider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
        let textView = NSTextView()
        let button = NSButton()

        #expect(PlayerKeyboardRouting.shouldDefer(
            action: .seek(5),
            firstResponder: slider
        ))
        #expect(PlayerKeyboardRouting.shouldDefer(
            action: .togglePause,
            firstResponder: textView
        ))
        #expect(PlayerKeyboardRouting.shouldDefer(
            action: .togglePause,
            firstResponder: button
        ))
        #expect(!PlayerKeyboardRouting.shouldDefer(
            action: .toggleMute,
            firstResponder: slider
        ))
        #expect(PlayerKeyboardRouting.shouldDefer(
            action: .seek(5),
            firstResponder: slider,
            isPlaybackChromeVisible: false
        ))
        #expect(PlayerKeyboardRouting.shouldDefer(
            action: .togglePause,
            firstResponder: textView,
            isPlaybackChromeVisible: false
        ))
        #expect(PlayerKeyboardRouting.shouldDefer(
            action: .dismiss,
            firstResponder: button,
            isPlaybackChromeVisible: false,
            isWindowFullscreen: true
        ))
        #expect(PlayerKeyboardRouting.shouldDefer(
            action: .seek(5),
            firstResponder: slider,
            isPlaybackChromeVisible: false,
            isWindowFullscreen: true
        ))
    }
}

@Suite("Playback chrome pointer reveal")
struct PlaybackChromePointerRevealTests {
    @Test func playerWindowBoundaryRejectsExitEvents() {
        let windowSize = CGSize(width: 800, height: 500)

        #expect(PlayerWindowPointerPolicy.isInsideWindow(
            locationInWindow: CGPoint(x: 400, y: 250),
            windowSize: windowSize
        ))
        #expect(!PlayerWindowPointerPolicy.isInsideWindow(
            locationInWindow: CGPoint(x: -1, y: 250),
            windowSize: windowSize
        ))
        #expect(!PlayerWindowPointerPolicy.isInsideWindow(
            locationInWindow: CGPoint(x: 801, y: 250),
            windowSize: windowSize
        ))
    }

    @Test func screenLocationDistinguishesWindowExitFromInternalSurfaceExit() {
        let windowFrame = CGRect(x: 200, y: 100, width: 800, height: 500)

        #expect(PlayerWindowPointerPolicy.isInsideWindow(
            mouseLocationOnScreen: CGPoint(x: 240, y: 450),
            windowFrame: windowFrame
        ))
        #expect(!PlayerWindowPointerPolicy.isInsideWindow(
            mouseLocationOnScreen: CGPoint(x: 199, y: 450),
            windowFrame: windowFrame
        ))
    }

    @Test func screenLocationRejectsAStaleInsideWindowMovementSample() {
        let windowFrame = CGRect(x: 200, y: 100, width: 800, height: 500)

        #expect(!PlayerWindowPointerPolicy.isInsideWindow(
            locationInWindow: CGPoint(x: 400, y: 250),
            mouseLocationOnScreen: CGPoint(x: 199, y: 450),
            windowFrame: windowFrame
        ))
        #expect(PlayerWindowPointerPolicy.isInsideWindow(
            locationInWindow: CGPoint(x: 400, y: 250),
            mouseLocationOnScreen: CGPoint(x: 600, y: 350),
            windowFrame: windowFrame
        ))
    }

    @Test func ignoresPointerJitterUntilMovementIsDeliberate() {
        var gate = PointerRevealGate()
        gate.noteVisiblePointer(at: CGPoint(x: 100, y: 100))
        gate.controlsDidHide()

        let revealsForJitter = gate.shouldReveal(at: CGPoint(x: 102, y: 101))
        let revealsForSmallMove = gate.shouldReveal(at: CGPoint(x: 106, y: 102))
        let revealsForDeliberateMove = gate.shouldReveal(at: CGPoint(x: 109, y: 100))

        #expect(!revealsForJitter)
        #expect(!revealsForSmallMove)
        #expect(revealsForDeliberateMove)
    }

    @Test func establishesAnAnchorWhenNoPriorPointerPositionExists() {
        var gate = PointerRevealGate()

        let revealsForFirstSample = gate.shouldReveal(at: CGPoint(x: 40, y: 50))
        let revealsForSmallMove = gate.shouldReveal(at: CGPoint(x: 46, y: 52))
        let revealsForDeliberateMove = gate.shouldReveal(at: CGPoint(x: 49, y: 50))

        #expect(!revealsForFirstSample)
        #expect(!revealsForSmallMove)
        #expect(revealsForDeliberateMove)
    }

    @Test func postPlayCooldownRequiresFreshDeliberateMovement() {
        var gate = PointerRevealGate(postPlayCooldown: 0.25)
        gate.noteVisiblePointer(at: CGPoint(x: 100, y: 100))
        gate.controlsDidHide()
        gate.beginPostPlayCooldown(at: 10)

        let revealsDuringCooldown = gate.shouldReveal(
            at: CGPoint(x: 200, y: 100),
            now: 10.1
        )
        let establishesFreshAnchorAfterCooldown = gate.shouldReveal(
            at: CGPoint(x: 230, y: 100),
            now: 10.25
        )
        let revealsForSmallMoveAfterCooldown = gate.shouldReveal(
            at: CGPoint(x: 235, y: 100),
            now: 10.3
        )
        let revealsForDeliberateMoveAfterCooldown = gate.shouldReveal(
            at: CGPoint(x: 239, y: 100),
            now: 10.35
        )

        #expect(!revealsDuringCooldown)
        #expect(!establishesFreshAnchorAfterCooldown)
        #expect(!revealsForSmallMoveAfterCooldown)
        #expect(revealsForDeliberateMoveAfterCooldown)
    }
}

@Suite("Playback chrome activity")
struct PlaybackChromeActivityTests {
    @Test func keyboardSeekSuppressesOnlyItsOwnTransientLoadingPin() {
        let source = MediaSource.localFile(URL(fileURLWithPath: "/tmp/video.mp4"))
        let replacement = MediaSource.localFile(URL(fileURLWithPath: "/tmp/other.mp4"))
        var suppression = KeyboardSeekChromeSuppression()

        let ordinaryLoadingPin = suppression.loadingPinIsActive(
            source: source,
            isLoading: true
        )
        #expect(ordinaryLoadingPin)

        suppression.begin(for: source)
        let keyboardSeekLoadingPin = suppression.loadingPinIsActive(
            source: source,
            isLoading: true
        )
        #expect(!keyboardSeekLoadingPin)
        #expect(suppression.hasObservedLoading)
        let settledLoadingPin = suppression.loadingPinIsActive(
            source: source,
            isLoading: false
        )
        #expect(!settledLoadingPin)

        let laterLoadingPin = suppression.loadingPinIsActive(
            source: source,
            isLoading: true
        )
        #expect(laterLoadingPin)

        suppression.begin(for: source)
        let replacementLoadingPin = suppression.loadingPinIsActive(
            source: replacement,
            isLoading: true
        )
        #expect(replacementLoadingPin)
    }

    @Test func keyboardSeekSuppressionExpiresIfLoadingNeverBegins() {
        let source = MediaSource.localFile(URL(fileURLWithPath: "/tmp/video.mp4"))
        var suppression = KeyboardSeekChromeSuppression()

        suppression.begin(for: source)
        suppression.expireIfAwaiting(for: source)

        #expect(suppression.source == nil)
        let loadingPin = suppression.loadingPinIsActive(source: source, isLoading: true)
        #expect(loadingPin)
    }

    @Test func playbackActivityAlwaysReceivesAnAutoHideDeadline() {
        var machine = PlaybackChromeStateMachine()
        machine.registerActivity(at: 2)
        #expect(machine.phase == .visible)
        #expect(machine.deadline == .autoHide(4.5))

        machine.deadlineReached(at: 4.5, reducedMotion: true)
        #expect(machine.phase == .hidden)
        #expect(machine.deadline == nil)
    }

    @Test func activityUsesTheSharedTwoAndAHalfSecondDeadline() {
        var machine = PlaybackChromeStateMachine()
        machine.registerActivity(at: 10)

        #expect(machine.phase == .visible)
        #expect(machine.deadline == .autoHide(12.5))
    }

    @Test func movementExtendsDeadlineWithoutChangingVisibility() {
        var machine = PlaybackChromeStateMachine()
        machine.registerActivity(at: 10)
        machine.registerActivity(at: 11)

        #expect(machine.phase == .visible)
        #expect(machine.deadline == .autoHide(13.5))
    }

    @Test func launchRevealsHiddenChromeThenUsesTheSharedDeadline() {
        var machine = PlaybackChromeStateMachine()
        machine.registerActivity(at: 1)
        machine.deadlineReached(at: 3.5, reducedMotion: true)
        #expect(machine.phase == .hidden)

        machine.revealForLaunch(at: 10)

        #expect(machine.phase == .revealing)
        #expect(machine.deadline == .autoHide(12.5))
    }

    @Test func autoHideFadesBeforeUnmounting() {
        var machine = PlaybackChromeStateMachine()
        machine.registerActivity(at: 10)
        machine.deadlineReached(at: 12.5, reducedMotion: false)

        #expect(machine.phase == .hiding)
        #expect(machine.phase.isMounted)
        #expect(!machine.phase.isOpaque)
        #expect(machine.deadline == .finishHiding(12.725))

        machine.deadlineReached(at: 12.725, reducedMotion: false)
        #expect(machine.phase == .hidden)
        #expect(!machine.phase.isMounted)
    }

    @Test func reducedMotionUnmountsAtTheHideDeadline() {
        var machine = PlaybackChromeStateMachine()
        machine.registerActivity(at: 10)
        machine.deadlineReached(at: 12.5, reducedMotion: true)

        #expect(machine.phase == .hidden)
        #expect(machine.deadline == nil)
    }

    @Test func everyInteractionReasonPinsAndLastRemovalStartsOneDeadline() {
        for reason in PlaybackChromePinReason.allCases {
            var machine = PlaybackChromeStateMachine()
            machine.registerActivity(at: 1)
            machine.setPin(reason, active: true, now: 2)
            #expect(machine.phase == .pinned)
            #expect(machine.deadline == nil)
            #expect(machine.pinReasons == [reason])

            machine.setPin(reason, active: false, now: 3)
            #expect(machine.phase == .visible)
            #expect(machine.deadline == .autoHide(5.5))
        }
    }

    @Test func removingOneOfSeveralPinsDoesNotBeginHiding() {
        var machine = PlaybackChromeStateMachine()
        machine.setPin(.scrubbing, active: true, now: 1)
        machine.setPin(.volumePopover, active: true, now: 1)
        machine.setPin(.scrubbing, active: false, now: 2)

        #expect(machine.phase == .pinned)
        #expect(machine.pinReasons == [.volumePopover])
        #expect(machine.deadline == nil)
    }

    @Test func hoveringSidebarPreventsImmediateOrScheduledChromeHide() {
        var machine = PlaybackChromeStateMachine()
        machine.registerActivity(at: 1)
        machine.setPin(.pointerOverSidebar, active: true, now: 2)
        machine.hideImmediately(reducedMotion: true, now: 3)
        machine.deadlineReached(at: 10, reducedMotion: true)

        #expect(machine.phase == .pinned)
        #expect(machine.deadline == nil)

        machine.setPin(.pointerOverSidebar, active: false, now: 10)
        #expect(machine.phase == .visible)
        #expect(machine.deadline == .autoHide(12.5))
    }

    @Test func videoSurfaceClickHidesVisibleChromeAndClearsStalePassivePins() {
        var machine = PlaybackChromeStateMachine()
        machine.registerActivity(at: 1)
        machine.setPin(.pointerOverChrome, active: true, now: 2)
        machine.setPin(.chromeFocus, active: true, now: 2)

        machine.handleSurfaceClick(reducedMotion: true, now: 3)

        #expect(machine.phase == .hidden)
        #expect(machine.pinReasons.isEmpty)
        #expect(machine.deadline == nil)
    }

    @Test func videoSurfaceClickRevealsHiddenChrome() {
        var machine = PlaybackChromeStateMachine()
        machine.registerActivity(at: 1)
        machine.hideImmediately(reducedMotion: true, now: 2)

        machine.handleSurfaceClick(reducedMotion: true, now: 3)

        #expect(machine.phase == .revealing)
        #expect(machine.pinReasons.isEmpty)
        #expect(machine.deadline == .autoHide(5.5))
    }

    @Test func leavingPlayerWindowHidesChromeAndClearsHoverPins() {
        var machine = PlaybackChromeStateMachine()
        machine.registerActivity(at: 1)
        machine.setPin(.pointerOverChrome, active: true, now: 2)
        machine.setPin(.pointerOverSidebar, active: true, now: 2)
        machine.setPin(.chromeFocus, active: true, now: 2)

        machine.hideForPointerExit(reducedMotion: true, now: 3)

        #expect(machine.phase == .hidden)
        #expect(machine.pinReasons.isEmpty)
        #expect(machine.deadline == nil)
    }

    @Test func leavingPlayerWindowPreservesActiveInteractions() {
        var machine = PlaybackChromeStateMachine()
        machine.setPin(.pointerOverChrome, active: true, now: 1)
        machine.setPin(.scrubbing, active: true, now: 1)

        machine.hideForPointerExit(reducedMotion: true, now: 2)

        #expect(machine.phase == .pinned)
        #expect(machine.pinReasons == [.scrubbing])
        #expect(machine.deadline == nil)
    }

    @Test func finishingScrubOutsideHidesAndSeekCommitCannotRevealChrome() {
        var machine = PlaybackChromeStateMachine()
        machine.setPin(.scrubbing, active: true, now: 1)
        machine.hideForPointerExit(reducedMotion: true, now: 2)

        machine.setPin(.scrubbing, active: false, now: 3)
        machine.registerActivity(at: 3)

        #expect(machine.phase == .hidden)
        #expect(machine.pinReasons.isEmpty)
        #expect(machine.deadline == nil)
        #expect(machine.isPointerOutside)

        machine.registerPointerActivity(at: 4)

        #expect(machine.phase == .revealing)
        #expect(machine.deadline == .autoHide(6.5))
        #expect(!machine.isPointerOutside)
    }

    @Test func keyboardPlayHidesImmediatelyThroughPassiveHoverPins() {
        var machine = PlaybackChromeStateMachine()
        machine.registerActivity(at: 1)
        machine.setPin(.pointerOverSidebar, active: true, now: 2)

        machine.hideImmediatelyForKeyboardPlay()

        #expect(machine.phase == .hidden)
        #expect(machine.deadline == nil)
        #expect(machine.pinReasons.isEmpty)
    }

    @Test func keyboardPlayPreservesActiveInteractionPins() {
        var machine = PlaybackChromeStateMachine()
        machine.setPin(.scrubbing, active: true, now: 1)

        machine.hideImmediatelyForKeyboardPlay()

        #expect(machine.phase == .pinned)
        #expect(machine.deadline == nil)
        #expect(machine.pinReasons == [.scrubbing])
    }

    @Test func pictureInPictureStartHidesSourceChromeThroughPassiveHoverPins() {
        var machine = PlaybackChromeStateMachine()
        machine.registerActivity(at: 1)
        machine.setPin(.pointerOverChrome, active: true, now: 2)

        machine.hideImmediatelyForPictureInPictureStart()

        #expect(machine.phase == .hidden)
        #expect(machine.deadline == nil)
        #expect(machine.pinReasons.isEmpty)
    }

    @Test func pictureInPictureStartPreservesActiveManipulationPins() {
        var machine = PlaybackChromeStateMachine()
        machine.setPin(.scrubbing, active: true, now: 1)

        machine.hideImmediatelyForPictureInPictureStart()

        #expect(machine.phase == .pinned)
        #expect(machine.deadline == nil)
        #expect(machine.pinReasons == [.scrubbing])
    }
}

@Suite("Playback cursor visibility")
struct PlaybackCursorVisibilityTests {
    @Test func hidesOnlyOverFullscreenRestingVideoWithHiddenChrome() {
        let base = PlaybackCursorPolicy(
            hasMedia: true,
            isWindowActive: true,
            isFullscreen: false,
            chromePhase: .hidden,
            region: .video,
            hasTransientPresentation: false
        )
        #expect(!base.shouldHide)
        #expect(base.shouldPreventSystemAutoHide)

        var policy = base
        policy.isFullscreen = true
        #expect(policy.shouldHide)
        #expect(!policy.shouldPreventSystemAutoHide)
        policy.chromePhase = .visible
        #expect(!policy.shouldHide)
        policy.chromePhase = .hidden
        policy.region = .chrome
        #expect(policy.shouldHide, "hidden chrome leaves its last hover region stale")
        policy.region = .sidebar
        #expect(!policy.shouldHide)
        policy.region = .titlebar
        #expect(!policy.shouldHide)
        policy.region = .video
        policy.hasTransientPresentation = true
        #expect(!policy.shouldHide)
        policy.hasTransientPresentation = false
        policy.isWindowActive = false
        #expect(!policy.shouldHide)
        policy.isWindowActive = true
        policy.hasMedia = false
        #expect(!policy.shouldHide)
    }
}

@Suite("Video surface interaction routing")
struct VideoSurfaceInteractionRoutingTests {
    @Test func contextMenuFiltersUnavailableCapabilitiesAndSourceActions() {
        let local = PlayerContextMenuAvailability(
            capabilities: PlayerCapabilityModel(capabilities: [
                .localFiles,
                .relativeSeeking,
                .audioTracks,
                .subtitleTracks,
            ]),
            hasSource: true,
            isLocalSource: true,
            hasPrevious: false,
            hasNext: true
        ).actions

        #expect(local.contains(.playPause))
        #expect(local.contains(.next))
        #expect(!local.contains(.previous))
        #expect(local.contains(.seekBackward))
        #expect(local.contains(.audioTracks))
        #expect(local.contains(.subtitles))
        #expect(local.contains(.showInFinder))
        #expect(!local.contains(.pictureInPicture))
        #expect(!local.contains(.screenshot))

        let remote = PlayerContextMenuAvailability(
            capabilities: PlayerCapabilityModel(capabilities: [.remoteStreams]),
            hasSource: true,
            isLocalSource: false,
            hasPrevious: false,
            hasNext: false
        ).actions
        #expect(!remote.contains(.showInFinder))
        #expect(remote.contains(.copyPath))
        #expect(remote.contains(.alwaysOnTop))
    }

    @Test func horizontalScrollAccumulatesIntoSeekAndVerticalScrollChangesVolume() {
        var accumulator = SurfaceScrollAccumulator()
        let small = accumulator.consume(PlaybackSurfaceScroll(
            deltaX: 4,
            deltaY: 0,
            isPrecise: true,
            phase: .began
        ))
        #expect(small == nil)
        let seek = accumulator.consume(PlaybackSurfaceScroll(
            deltaX: 4,
            deltaY: 0,
            isPrecise: true,
            phase: .changed
        ))
        #expect(seek == .seek(5))

        let volume = accumulator.consume(PlaybackSurfaceScroll(
            deltaX: 0,
            deltaY: -2,
            isPrecise: false,
            phase: .discrete
        ))
        #expect(volume == .volume(-10))
    }

    @Test func scrollAxisRemainsStableThroughMomentumAndResetsAtEnd() {
        var accumulator = SurfaceScrollAccumulator()
        _ = accumulator.consume(PlaybackSurfaceScroll(
            deltaX: 9,
            deltaY: 1,
            isPrecise: true,
            phase: .began
        ))
        let momentum = accumulator.consume(PlaybackSurfaceScroll(
            deltaX: 8,
            deltaY: 20,
            isPrecise: true,
            phase: .momentum
        ))
        #expect(momentum == .seek(5))
        _ = accumulator.consume(PlaybackSurfaceScroll(
            deltaX: 0,
            deltaY: 0,
            isPrecise: true,
            phase: .ended
        ))
        let nextGesture = accumulator.consume(PlaybackSurfaceScroll(
            deltaX: 0,
            deltaY: 2,
            isPrecise: true,
            phase: .began
        ))
        #expect(nextGesture == .volume(1))
    }

    @Test func repeatedSeekTargetsAccumulateAndUndoReturnsTheSequenceOrigin() {
        var accumulator = SeekInteractionAccumulator()
        let first = accumulator.relativeTarget(
            delta: 5,
            currentPosition: 100,
            duration: 500,
            at: 1
        )
        let second = accumulator.relativeTarget(
            delta: 5,
            currentPosition: 101,
            duration: 500,
            at: 1.1
        )
        let third = accumulator.relativeTarget(
            delta: -5,
            currentPosition: 102,
            duration: 500,
            at: 1.2
        )
        let undo = accumulator.undoTarget()
        let duplicateUndo = accumulator.undoTarget()

        #expect(first == 105)
        #expect(second == 110)
        #expect(third == 105)
        #expect(undo == 100)
        #expect(duplicateUndo == nil)
    }
}

@Suite("Playback OSD")
struct PlaybackOSDTests {
    @Test func repeatedSeeksCoalesceAndExtendOneLifetime() {
        var osd = PlaybackOSDStateMachine()
        osd.present(.seek(delta: 5, target: 105), at: 1)
        osd.present(.seek(delta: 5, target: 110), at: 1.2)

        #expect(osd.item == .seek(delta: 10, target: 110))
        #expect(osd.deadline == 2.2)
        osd.deadlineReached(at: 2)
        #expect(osd.item != nil)
        osd.deadlineReached(at: 2.2)
        #expect(osd.item == nil)
    }

    @Test func volumeUpdatesReplaceInsteadOfStacking() {
        var osd = PlaybackOSDStateMachine()
        osd.present(.volume(value: 40, isMuted: false), at: 1)
        osd.present(.volume(value: 45, isMuted: false), at: 1.1)

        #expect(osd.item == .volume(value: 45, isMuted: false))
        #expect(osd.deadline == 2.1)
    }

    @MainActor
    @Test func presenterKeepsBoundedHistoryAndCoalescesSeekBursts() {
        let presenter = PlaybackOSDPresenter()

        presenter.present(.seek(delta: 5, target: 105))
        presenter.present(.seek(delta: 5, target: 110))
        presenter.present(.mediaCompleted("Episode 1"))

        #expect(presenter.messages.count == 2)
        #expect(presenter.messages[0].item == .seek(delta: 10, target: 110))
        #expect(presenter.messages[1].item == .mediaCompleted("Episode 1"))

        for index in 0 ..< 60 {
            presenter.present(.status("Message \(index)"))
        }

        #expect(presenter.messages.count == 50)
        #expect(presenter.messages.last?.item == .status("Message 59"))

        presenter.clearHistory()
        #expect(presenter.messages.isEmpty)
        presenter.invalidate()
    }

    @Test func playbackLifecycleMessagesUseFriendlyCopy() {
        #expect(PlaybackOSDItem.mediaChanged("Episode 2").text == "Opened Episode 2")
        #expect(PlaybackOSDItem.mediaCompleted("Episode 1").text == "Finished Episode 1")
    }
}

@Suite("Playback chrome mount policy")
struct PlaybackChromeMountPolicyTests {
    @Test func mountsOnlyForAVisibleLoadedPlayer() {
        #expect(PlaybackChromeMountPolicy.shouldMount(
            hasSource: true,
            isVisible: true,
            isPictureInPictureActive: false
        ))
        #expect(!PlaybackChromeMountPolicy.shouldMount(
            hasSource: true,
            isVisible: false,
            isPictureInPictureActive: false
        ))
        #expect(!PlaybackChromeMountPolicy.shouldMount(
            hasSource: false,
            isVisible: true,
            isPictureInPictureActive: false
        ))
    }

    @Test func remainsUnmountedDuringPictureInPicture() {
        #expect(!PlaybackChromeMountPolicy.shouldMount(
            hasSource: true,
            isVisible: true,
            isPictureInPictureActive: true
        ))
    }

    @Test func centeredTransportUsesTenSecondRelativeSeeks() {
        #expect(CenterTransportControlPolicy.seekInterval == 10)
    }

    @Test func centeredTransportStaysWindowCenteredWhenSidebarIsOpen() {
        #expect(CenterTransportControlPolicy.horizontalCompensation(
            sidebarOccupiedWidth: 0, availableWidth: 1200
        ) == 0)
        #expect(CenterTransportControlPolicy.horizontalCompensation(
            sidebarOccupiedWidth: 380, availableWidth: 820
        ) == -190)
    }

    @Test func compactTransportTargetsStayInsideTheUncoveredRegion() {
        for windowWidth: CGFloat in [720, 820, 840, 1024, 1440] {
            let occupied: CGFloat = min(380, windowWidth - 332)
            let available = windowWidth - occupied
            let offset = CenterTransportControlPolicy.horizontalCompensation(
                sidebarOccupiedWidth: occupied, availableWidth: available
            )
            let center = occupied + available / 2 + offset
            #expect(center - 148 >= occupied + 16)
            #expect(center + 148 <= windowWidth - 16)
        }
    }
}

@Suite("Sidebar toggle control")
struct SidebarToggleControlPolicyTests {
    @Test func labelDescribesTheAvailableAction() {
        #expect(SidebarToggleControlPolicy.title(isSidebarVisible: true) == "Hide Sources")
        #expect(SidebarToggleControlPolicy.title(isSidebarVisible: false) == "Show Sources")
    }
}

@Suite("Subtitle control visual state")
struct SubtitleControlVisualStateTests {
    @Test func offDoesNotUseTheActiveAccent() {
        let state = SubtitleControlVisualState(selectedTrack: nil)

        #expect(state == .off)
        #expect(!state.usesAccentTint)
        #expect(state.accessibilityValue == "Off")
    }

    @Test func selectedTrackUsesTheActiveAccent() {
        let track = MediaTrack(
            id: 2,
            kind: .subtitle,
            title: "English",
            languageCode: "eng",
            codec: "ass"
        )
        let state = SubtitleControlVisualState(selectedTrack: track)

        #expect(state == .active)
        #expect(state.usesAccentTint)
        #expect(state.accessibilityValue == "On")
    }
}

@Suite("Playback chrome refresh policy")
struct PlaybackChromeRefreshPolicyTests {
    @Test func passivePositionViewsUseBoundedUIRates() {
        #expect(PlaybackChromeRefreshPolicy.timelinePositionInterval == .milliseconds(200))
        #expect(PlaybackChromeRefreshPolicy.sourceProgressInterval == .seconds(1))
    }

    @Test func passivePollingRunsOnlyForVisibleActivePlayback() {
        #expect(PlaybackTimelineInteraction.shouldRefreshContinuously(
            phase: .playing,
            isObservationActive: true
        ))
        #expect(!PlaybackTimelineInteraction.shouldRefreshContinuously(
            phase: .paused,
            isObservationActive: true
        ))
        #expect(!PlaybackTimelineInteraction.shouldRefreshContinuously(
            phase: .playing,
            isObservationActive: false
        ))
        #expect(NowPlayingRefreshPolicy.shouldRefreshContinuously(phase: .playing))
        #expect(!NowPlayingRefreshPolicy.shouldRefreshContinuously(phase: .paused))
        #expect(!NowPlayingRefreshPolicy.shouldRefreshContinuously(phase: .buffering))
    }
}

@Suite("Playback timeline interaction")
struct PlaybackTimelineInteractionTests {
    @Test func hoverPositionClampsToTheSliderRange() {
        let frame = CGRect(x: 50, y: 0, width: 200, height: 20)
        #expect(PlaybackTimelineInteraction.position(
            forX: 150,
            sliderFrame: frame,
            duration: 120
        ) == 60)
        #expect(PlaybackTimelineInteraction.position(
            forX: 0,
            sliderFrame: frame,
            duration: 120
        ) == 0)
        #expect(PlaybackTimelineInteraction.position(
            forX: 400,
            sliderFrame: frame,
            duration: 120
        ) == 120)
    }

    @Test func hoverSelectsTheLatestStartedChapter() {
        let chapters = [
            Chapter(id: 0, title: "Opening", startTime: 0),
            Chapter(id: 1, title: "Act One", startTime: 45),
            Chapter(id: 2, title: "Act Two", startTime: 90),
        ]
        #expect(PlaybackTimelineInteraction.chapterTitle(
            at: 70,
            chapters: chapters
        ) == "Act One")
    }

    @Test func durationLabelTogglesBetweenTotalAndRemaining() {
        #expect(PlaybackTimelineInteraction.durationLabel(
            position: 30,
            duration: 120,
            showsRemaining: false
        ) == "02:00")
        #expect(PlaybackTimelineInteraction.durationLabel(
            position: 30,
            duration: 120,
            showsRemaining: true
        ) == "−01:30")
    }

    @Test func bufferFractionIsBounded() {
        #expect(PlaybackTimelineInteraction.bufferFraction(
            BufferStatus(cachePercent: 25)
        ) == 0.25)
        #expect(PlaybackTimelineInteraction.bufferFraction(
            BufferStatus(cachePercent: nil)
        ) == 0)
    }
}

@Suite("Window UI observation policy")
struct WindowUIObservationPolicyTests {
    @Test func continuousUIWorkRequiresAnActiveVisibleUnoccludedWindow() {
        #expect(WindowUIObservationPolicy.shouldObserve(
            isApplicationActive: true,
            isWindowVisible: true,
            isMiniaturized: false,
            isOccluded: false
        ))
        #expect(!WindowUIObservationPolicy.shouldObserve(
            isApplicationActive: false,
            isWindowVisible: true,
            isMiniaturized: false,
            isOccluded: false
        ))
        #expect(!WindowUIObservationPolicy.shouldObserve(
            isApplicationActive: true,
            isWindowVisible: true,
            isMiniaturized: true,
            isOccluded: false
        ))
        #expect(!WindowUIObservationPolicy.shouldObserve(
            isApplicationActive: true,
            isWindowVisible: true,
            isMiniaturized: false,
            isOccluded: true
        ))
    }
}

@Suite("Player window lifecycle")
@MainActor
struct PlayerWindowLifecycleTests {
    @Test func swiftUICreatesTheApplicationDelegateThroughItsRuntimeInitializer() {
        // Calling AppDelegate() directly can select a Swift initializer whose
        // arguments have defaults. Exercise the adaptor used by the real app.
        let adaptor = NSApplicationDelegateAdaptor(AppDelegate.self)
        #expect(adaptor.wrappedValue.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    @Test func failedFinalSaveIsAcknowledgedBeforeTerminationReply() async {
        var events: [String] = []
        let delegate = AppDelegate(shutdown: {
            events.append("cleanup")
            await Task.yield()
            return "Disk is full"
        }, presentSaveFailure: { details in
            #expect(details == "Disk is full")
            #expect(events == ["cleanup"])
            events.append("acknowledgement")
        })
        await delegate.finishTermination { events.append("reply") }
        #expect(events == ["cleanup", "acknowledgement", "reply"])
        #expect(delegate.applicationShouldTerminate(.shared) == .terminateNow)
    }

    @Test func successfulFinalSaveTerminatesWithoutNotice() async {
        var replied = false
        let delegate = AppDelegate(shutdown: { nil }, presentSaveFailure: { _ in
            Issue.record("Successful save must not show a failure notice")
        })
        await delegate.finishTermination { replied = true }
        #expect(replied)
    }

    @Test func closingThePlayerWindowTerminatesTheApplication() {
        let delegate = AppDelegate()

        #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
    }

    @Test func pictureInPictureRestoreWaitsForVisibleWindowAndAttachedSurface() {
        #expect(!PlayerWindowRestoreReadiness.shouldReportSuccess(
            windowExists: false,
            windowVisible: false,
            windowMiniaturized: false,
            surfaceAttached: false
        ))
        #expect(!PlayerWindowRestoreReadiness.shouldReportSuccess(
            windowExists: true,
            windowVisible: true,
            windowMiniaturized: false,
            surfaceAttached: false
        ))
        #expect(!PlayerWindowRestoreReadiness.shouldReportSuccess(
            windowExists: true,
            windowVisible: true,
            windowMiniaturized: true,
            surfaceAttached: true
        ))
        #expect(PlayerWindowRestoreReadiness.shouldReportSuccess(
            windowExists: true,
            windowVisible: true,
            windowMiniaturized: false,
            surfaceAttached: true
        ))
    }
}

@Suite("Video surface failure fallback")
@MainActor
struct VideoSurfaceFailureFallbackTests {
    @Test func unavailableSurfaceIsInertInsteadOfTerminatingTheProcess() {
        let message = "The system could not create a video surface: unavailable"
        let view = VideoSurfaceUnavailableView(message: message)

        #expect(view.failureMessage == message)
        #expect(view.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
            == [message])
    }
}

@Suite("Platinum motion policy")
struct PlatinumMotionPolicyTests {
    @Test func sharedMotionTokensStayWithinTheNativeResponseBands() {
        #expect((0.08 ... 0.12).contains(PlatinumMotion.Duration.micro))
        #expect((0.12 ... 0.17).contains(PlatinumMotion.Duration.control))
        #expect((0.18 ... 0.24).contains(PlatinumMotion.Duration.panel))
        #expect((0.24 ... 0.34).contains(PlatinumMotion.Duration.major))
        #expect(PlaybackChromeStateMachine.defaultFadeDuration
            == PlatinumMotion.Duration.panel)
    }

    @Test func reducedMotionRemovesSpatialMotion() {
        #expect(PlatinumMotion.offset(12, reduceMotion: true) == 0)
        #expect(PlatinumMotion.scale(0.97, reduceMotion: true) == 1)
        #expect(PlatinumMotion.offset(12, reduceMotion: false) == 12)
        #expect(PlatinumMotion.scale(0.97, reduceMotion: false) == 0.97)
    }

    @Test func appMotionHasNoContinuousIdleAnimation() {
        #expect(!PlatinumMotion.usesContinuousAnimation)
    }
}

@Suite("Playback control bar feature gate")
struct PlaybackControlBarFeatureGateTests {
    @Test func elasticBarIsTheTemporaryDefault() {
        #expect(PlaybackControlBarFeatureGate.implementation(
            arguments: ["Platinum"]
        ) == .elastic)
    }

    @Test func legacyBarRequiresTheExplicitFallbackArgument() {
        #expect(PlaybackControlBarFeatureGate.implementation(arguments: [
            "Platinum",
            PlaybackControlBarFeatureGate.legacyLaunchArgument,
        ]) == .legacy)
    }
}

@Suite("Timeline thumbnail hover policy")
struct TimelineThumbnailHoverPolicyTests {
    @Test func cacheMissDebounceRemainsBrief() {
        #expect(TimelineThumbnailHoverPolicy.cacheMissDelay == .milliseconds(40))
    }
}

@Suite("Subtitle delay input")
struct SubtitleDelayInputTests {
    @Test func parsesWholeMillisecondsWithinTheSupportedRange() {
        #expect(SubtitleDelayInput.seconds(fromMillisecondsText: "-1250") == -1.25)
        #expect(SubtitleDelayInput.seconds(fromMillisecondsText: " +200 ") == 0.2)
        #expect(SubtitleDelayInput.seconds(fromMillisecondsText: "10000") == 10)
        #expect(SubtitleDelayInput.seconds(fromMillisecondsText: "10001") == nil)
        #expect(SubtitleDelayInput.seconds(fromMillisecondsText: "1.5") == nil)
        #expect(SubtitleDelayInput.seconds(fromMillisecondsText: "later") == nil)
    }

    @Test func formatsStoredSecondsAsMilliseconds() {
        #expect(SubtitleDelayInput.millisecondsText(for: -1.25) == "-1250")
        #expect(SubtitleDelayInput.displayText(for: 0.2) == "+200 ms")
        #expect(SubtitleDelayInput.displayText(for: 0) == "0 ms")
    }
}

@Suite("Elastic playback control bar placement")
struct ElasticPlaybackControlBarPlacementTests {
    @Test func placementRoundTripsAcrossChromeRemountAndRelaunch() throws {
        let suiteName = "ElasticPlaybackControlBarPlacementTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var placement = ElasticPlaybackControlBarPlacement.defaultValue
        placement.normalizedCenter = CGPoint(x: 0.72, y: 0.34)
        placement.orientation = .up
        placement.bendDirection = .down

        ElasticPlaybackControlBarPlacementStore.persist(
            placement,
            defaults: defaults
        )
        let restored = ElasticPlaybackControlBarPlacementStore.restored(
            defaults: defaults
        )

        #expect(restored == placement)
        #expect(restored.normalizedCenter == CGPoint(x: 0.72, y: 0.34))
        #expect(restored.orientation == .up)
        #expect(restored.bendDirection == .down)
    }

    @Test func absentOrMalformedPlacementFallsBackToTheDefault() throws {
        let suiteName = "ElasticPlaybackControlBarPlacementTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(ElasticPlaybackControlBarPlacementStore.restored(
            defaults: defaults
        ) == .defaultValue)

        defaults.set(
            Data("not-a-placement".utf8),
            forKey: ElasticPlaybackControlBarPlacementStore.defaultsKey
        )
        #expect(ElasticPlaybackControlBarPlacementStore.restored(
            defaults: defaults
        ) == .defaultValue)
    }
}

@Suite("Elastic playback control bar geometry")
struct ElasticPlaybackControlBarGeometryTests {
    @Test func smallWindowKeepsSidebarAndTimelineInsideViewport() {
        for size in [CGSize(width: 720, height: 408), CGSize(width: 800, height: 418)] {
            let sidebar = SourcesSidebarSizing.settledWidth(
                storedWidth: 720,
                maximumWidth: SourcesSidebarSizing.maximumWidth(for: size.width)
            ) + SourcesSidebarLayoutPolicy.horizontalPadding
            for orientation in [ElasticPlaybackControlBarOrientation.right, .down, .left, .up] {
                let fullGeometry = ElasticPlaybackControlBarGeometry.avoidingSidebar(
                    containerSize: size,
                    center: ElasticPlaybackControlBarGeometry.defaultCenter(in: size),
                    utilityCount: 7,
                    bendDirection: .up,
                    orientation: orientation,
                    sidebarOccupiedWidth: sidebar
                )
                let utilities = ElasticPlaybackUtility.fitting(
                    [.volume, .audio, .subtitles, .sidebar, .pictureInPicture, .settings, .more],
                    length: fullGeometry.totalLength
                )
                let geometry = ElasticPlaybackControlBarGeometry.avoidingSidebar(
                    containerSize: size,
                    center: ElasticPlaybackControlBarGeometry.defaultCenter(in: size),
                    utilityCount: utilities.count,
                    bendDirection: .up,
                    orientation: orientation,
                    sidebarOccupiedWidth: sidebar
                )
                #expect(geometry.surfaceBounds.minX >= sidebar - 0.25)
                #expect(geometry.surfaceBounds.maxX <= size.width + 0.25)
                #expect(geometry.surfaceBounds.minY >= -0.25)
                #expect(geometry.surfaceBounds.maxY <= size.height + 0.25)
                #expect(geometry.trackEndS <= geometry.durationLabelS - 38 + 0.25)
                #expect(geometry.trackEndS - geometry.trackStartS >= 40)
            }
        }
    }

    @Test func sidebarLeavesANonOverlappingBarExactlyWhereItWas() {
        let size = CGSize(width: 1_800, height: 720)
        let center = ElasticPlaybackControlBarGeometry.defaultCenter(in: size)
        let natural = ElasticPlaybackControlBarGeometry(
            containerSize: size,
            center: center,
            utilityCount: 7,
            bendDirection: .up
        )
        let avoiding = ElasticPlaybackControlBarGeometry.avoidingSidebar(
            containerSize: size,
            center: center,
            utilityCount: 7,
            bendDirection: .up,
            sidebarOccupiedWidth: 380
        )

        #expect(natural.surfaceBounds.minX > 380)
        #expect(avoiding.center == natural.center)
        #expect(avoiding.surfaceBounds == natural.surfaceBounds)
    }

    @Test func sidebarMovesTheBarOnlyWhenItsSurfaceWouldOverlap() {
        let size = CGSize(width: 1_200, height: 720)
        let center = ElasticPlaybackControlBarGeometry.defaultCenter(in: size)
        let sidebarOccupiedWidth: CGFloat = 380
        let natural = ElasticPlaybackControlBarGeometry(
            containerSize: size,
            center: center,
            utilityCount: 7,
            bendDirection: .up
        )
        let avoiding = ElasticPlaybackControlBarGeometry.avoidingSidebar(
            containerSize: size,
            center: center,
            utilityCount: 7,
            bendDirection: .up,
            sidebarOccupiedWidth: sidebarOccupiedWidth
        )

        #expect(natural.surfaceBounds.minX < sidebarOccupiedWidth)
        #expect(avoiding.center.x > natural.center.x)
        #expect(avoiding.surfaceBounds.minX >= sidebarOccupiedWidth - 0.25)
    }

    @Test func sidebarAvoidanceClearsEveryBarOrientation() {
        let size = CGSize(width: 1_200, height: 720)
        let sidebarOccupiedWidth: CGFloat = 380

        for orientation in [
            ElasticPlaybackControlBarOrientation.right,
            .down,
            .left,
            .up,
        ] {
            let center = orientation.isHorizontal
                ? CGPoint(x: size.width / 2, y: size.height - 44)
                : CGPoint(x: 200, y: size.height / 2)
            let natural = ElasticPlaybackControlBarGeometry(
                containerSize: size,
                center: center,
                utilityCount: 7,
                bendDirection: .up,
                orientation: orientation
            )
            let avoiding = ElasticPlaybackControlBarGeometry.avoidingSidebar(
                containerSize: size,
                center: center,
                utilityCount: 7,
                bendDirection: .up,
                orientation: orientation,
                sidebarOccupiedWidth: sidebarOccupiedWidth
            )

            #expect(natural.surfaceBounds.minX < sidebarOccupiedWidth)
            #expect(avoiding.surfaceBounds.minX >= sidebarOccupiedWidth - 0.25)
        }
    }

    @Test func sidebarAvoidanceRecoversAnExtremeSavedCenter() {
        let size = CGSize(width: 1_200, height: 720)
        let sidebarOccupiedWidth: CGFloat = 380
        let avoiding = ElasticPlaybackControlBarGeometry.avoidingSidebar(
            containerSize: size,
            center: CGPoint(x: -10_000, y: size.height - 44),
            utilityCount: 7,
            bendDirection: .up,
            sidebarOccupiedWidth: sidebarOccupiedWidth
        )

        #expect(avoiding.surfaceBounds.minX >= sidebarOccupiedWidth - 0.25)
    }

    @Test func timelineThumbnailChoosesTheOpenSideOfTheBar() {
        let size = CGSize(width: 1_000, height: 720)
        let horizontalSurface = (0...20).map {
            CGPoint(x: 200 + CGFloat($0) * 30, y: 676)
        }
        let bottom = TimelineThumbnailPlacement.frame(
            anchor: CGPoint(x: 500, y: 676),
            tangentAngle: 0,
            surfacePoints: horizontalSurface,
            containerSize: size
        )
        let top = TimelineThumbnailPlacement.frame(
            anchor: CGPoint(x: 500, y: 44),
            tangentAngle: 0,
            surfacePoints: horizontalSurface.map { CGPoint(x: $0.x, y: 44) },
            containerSize: size
        )

        #expect(bottom.maxY < 676)
        #expect(top.minY > 44)
    }

    @Test func timelineThumbnailFlipsBesideVerticalBarsAndStaysInBounds() {
        let size = CGSize(width: 1_000, height: 720)
        let verticalSurface = (0...20).map {
            CGPoint(x: 44, y: 80 + CGFloat($0) * 28)
        }
        let left = TimelineThumbnailPlacement.frame(
            anchor: CGPoint(x: 44, y: 360),
            tangentAngle: .pi / 2,
            surfacePoints: verticalSurface,
            containerSize: size
        )
        let right = TimelineThumbnailPlacement.frame(
            anchor: CGPoint(x: 956, y: 360),
            tangentAngle: .pi / 2,
            surfacePoints: verticalSurface.map { CGPoint(x: 956, y: $0.y) },
            containerSize: size
        )

        #expect(left.minX > 44)
        #expect(right.maxX < 956)
        #expect(left.minX >= TimelineThumbnailPlacement.edgeInset)
        #expect(right.maxX <= size.width - TimelineThumbnailPlacement.edgeInset)
    }

    @Test func timelineThumbnailClampsNearCornersOfABentBar() {
        let size = CGSize(width: 1_000, height: 720)
        let geometry = ElasticPlaybackControlBarGeometry(
            containerSize: size,
            center: CGPoint(x: 954, y: 676),
            utilityCount: 7,
            bendDirection: .up
        )
        let fraction: CGFloat = 0.9
        let trackS = geometry.trackStartS
            + (geometry.trackEndS - geometry.trackStartS) * fraction
        let frame = TimelineThumbnailPlacement.frame(
            anchor: geometry.pointOnTrack(fraction: fraction),
            tangentAngle: geometry.tangentAngle(at: trackS),
            surfacePoints: geometry.surfacePoints,
            containerSize: size
        )

        #expect(frame.minX >= TimelineThumbnailPlacement.edgeInset)
        #expect(frame.minY >= TimelineThumbnailPlacement.edgeInset)
        #expect(frame.maxX <= size.width - TimelineThumbnailPlacement.edgeInset)
        #expect(frame.maxY <= size.height - TimelineThumbnailPlacement.edgeInset)
    }

    @Test func hoverRegionTracksOnlyTheVisibleElasticSurface() {
        let geometry = ElasticPlaybackControlBarGeometry(
            containerSize: CGSize(width: 1_000, height: 700),
            center: CGPoint(x: 500, y: 650),
            utilityCount: 7,
            bendDirection: .down
        )

        #expect(geometry.containsSurface(geometry.pointOnSurface(fraction: 0.5)))
        #expect(!geometry.containsSurface(CGPoint(x: 100, y: 100)))
    }

    @Test func dragTranslationIsAppliedOneToOneWithoutClamping() {
        let start = CGPoint(x: 420, y: 680)
        let translation = CGSize(width: 137, height: -219)

        #expect(
            ElasticPlaybackControlBarGeometry.movedCenter(
                from: start,
                translation: translation
            ) == CGPoint(x: 557, y: 461)
        )
    }

    @Test func approachingAnEdgeProducesGranularBendProgress() {
        let centered = ElasticPlaybackControlBarGeometry.deformation(
            centerX: 500,
            totalLength: 908,
            containerWidth: 1_000
        )
        let nearEdge = ElasticPlaybackControlBarGeometry.deformation(
            centerX: 550,
            totalLength: 908,
            containerWidth: 1_000
        )
        let farther = ElasticPlaybackControlBarGeometry.deformation(
            centerX: 650,
            totalLength: 908,
            containerWidth: 1_000
        )

        #expect(centered.progress == 0)
        #expect(nearEdge.progress > 0 && nearEdge.progress < 1)
        #expect(farther.progress > nearEdge.progress && farther.progress < 1)
    }

    @Test func sideAttachmentReleasesBeforeTheBarIsPerfectlyStraight() {
        #expect(ElasticPlaybackControlBarGeometry.edgeAttachmentStrength(
            for: 0.10
        ) == 0)
        #expect(ElasticPlaybackControlBarGeometry.edgeAttachmentStrength(
            for: 0.15
        ) > 0)
        #expect(ElasticPlaybackControlBarGeometry.edgeAttachmentStrength(
            for: 0.15
        ) < 1)
        #expect(ElasticPlaybackControlBarGeometry.edgeAttachmentStrength(
            for: 0.20
        ) == 1)
    }

    @Test func inwardDragGetsMoreTrackingTravelToBreakFreeFromAnEdge() {
        let rightEdge = ElasticPlaybackControlBarGeometry(
            containerSize: CGSize(width: 1_000, height: 720),
            center: CGPoint(x: 800, y: 360),
            utilityCount: 7,
            bendDirection: .up
        )

        #expect(rightEdge.side == .trailing)
        #expect(rightEdge.trackingCorrectionLimit(
            for: CGSize(width: -2, height: 0)
        ) == ElasticPlaybackControlBarGeometry.detachmentTrackingCorrection)
        #expect(rightEdge.trackingCorrectionLimit(
            for: CGSize(width: 2, height: 0)
        ) == ElasticPlaybackControlBarGeometry.standardTrackingCorrection)
    }

    @Test func middleProgressFormsAnLBeforeTheBarBecomesVertical() {
        let size = CGSize(width: 1_000, height: 720)
        let bent = ElasticPlaybackControlBarGeometry(
            containerSize: size,
            center: CGPoint(x: 850, y: 676),
            utilityCount: 7,
            bendDirection: .up
        )
        let vertical = ElasticPlaybackControlBarGeometry(
            containerSize: size,
            center: CGPoint(x: 1_190, y: 676),
            utilityCount: 7,
            bendDirection: .up
        )
        let bentHalfLength = bent.totalLength / 2
        let verticalHalfLength = vertical.totalLength / 2

        #expect(abs(bent.tangentAngle(at: -bentHalfLength)) < 0.01)
        #expect(abs(bent.tangentAngle(at: bentHalfLength) + .pi / 2) < 0.01)
        #expect(abs(vertical.tangentAngle(at: -verticalHalfLength) + .pi / 2) < 0.01)
        #expect(abs(vertical.tangentAngle(at: verticalHalfLength) + .pi / 2) < 0.01)
    }

    @Test func topCornerProducesADownwardBendAndKeepsEveryTipVisible() {
        let size = CGSize(width: 1_000, height: 720)
        let geometry = ElasticPlaybackControlBarGeometry(
            containerSize: size,
            center: CGPoint(x: 954, y: 44),
            utilityCount: 7,
            bendDirection: .down
        )
        let halfLength = geometry.totalLength / 2

        #expect(abs(geometry.tangentAngle(at: -halfLength)) < 0.05)
        #expect(abs(geometry.tangentAngle(at: halfLength) - .pi / 2) < 0.01)
        #expect(geometry.surfaceBounds.minX >= ElasticPlaybackControlBarGeometry.horizontalInset)
        #expect(geometry.surfaceBounds.maxX <= size.width - ElasticPlaybackControlBarGeometry.horizontalInset)
        #expect(geometry.surfaceBounds.minY >= ElasticPlaybackControlBarGeometry.topInset)
        #expect(geometry.surfaceBounds.maxY <= size.height - ElasticPlaybackControlBarGeometry.bottomInset)
    }

    @Test func lElbowLandsExactlyInTheBottomRightCornerWithoutMagneticAlignment() {
        let size = CGSize(width: 1_000, height: 720)
        let geometry = ElasticPlaybackControlBarGeometry(
            containerSize: size,
            center: CGPoint(x: 954, y: 676),
            utilityCount: 7,
            bendDirection: .up
        )
        let halfLength = geometry.totalLength / 2
        let elbowS = (0...240).map { index in
            -halfLength + geometry.totalLength * CGFloat(index) / 240
        }.min { lhs, rhs in
            abs(abs(geometry.tangentAngle(at: lhs)) - .pi / 4)
                < abs(abs(geometry.tangentAngle(at: rhs)) - .pi / 4)
        } ?? 0
        let elbow = geometry.point(at: elbowS)

        #expect(abs(geometry.tangentAngle(at: -halfLength)) < 0.01)
        #expect(abs(geometry.tangentAngle(at: halfLength) + .pi / 2) < 0.01)
        #expect(abs(
            elbow.x
                - (size.width
                    - ElasticPlaybackControlBarGeometry.horizontalInset
                    - ElasticPlaybackControlBarGeometry.thickness / 2)
        ) < 12, "the L elbow should reach the right corner before becoming vertical")
        #expect(abs(
            elbow.y
                - (size.height
                    - ElasticPlaybackControlBarGeometry.bottomInset
                    - ElasticPlaybackControlBarGeometry.thickness / 2)
        ) < 12, "the L elbow should remain on the bottom corner")
        #expect(abs(
            geometry.surfaceBounds.maxX
                - (size.width - ElasticPlaybackControlBarGeometry.horizontalInset)
        ) < 0.5)
        #expect(abs(
            geometry.surfaceBounds.maxY
                - (size.height - ElasticPlaybackControlBarGeometry.bottomInset)
        ) < 0.5)
    }

    @Test func grabbedPointTracksExactlyWhileBendingFreely() {
        let size = CGSize(width: 1_000, height: 720)
        let initialGeometry = ElasticPlaybackControlBarGeometry(
            containerSize: size,
            center: CGPoint(x: 500, y: 360),
            utilityCount: 7,
            bendDirection: .down
        )
        let grabFraction: CGFloat = 0.4
        let localOffset = CGPoint(x: 4, y: -8)
        let initialPoint = initialGeometry.grabPoint(
            surfaceFraction: grabFraction,
            localOffset: localOffset
        )
        let desiredPoint = CGPoint(x: initialPoint.x, y: initialPoint.y - 25)
        let center = ElasticPlaybackControlBarGeometry.centerTracking(
            desiredPoint: desiredPoint,
            surfaceFraction: grabFraction,
            localOffset: localOffset,
            initialCenter: CGPoint(x: 500, y: 335),
            containerSize: size,
            utilityCount: 7,
            bendDirection: .down
        )
        let geometry = ElasticPlaybackControlBarGeometry(
            containerSize: size,
            center: center,
            utilityCount: 7,
            bendDirection: .down
        )
        let landedPoint = geometry.grabPoint(
            surfaceFraction: grabFraction,
            localOffset: localOffset
        )

        #expect(hypot(landedPoint.x - desiredPoint.x, landedPoint.y - desiredPoint.y) < 0.75)
    }

    @Test func twoPointDragStepsNeverProduceAVisibleGeometryJump() {
        let size = CGSize(width: 1_000, height: 720)
        let initialCenter = CGPoint(x: 500, y: 676)
        let grabFraction: CGFloat = 0.5
        let initialGeometry = ElasticPlaybackControlBarGeometry(
            containerSize: size,
            center: initialCenter,
            utilityCount: 7,
            bendDirection: .up
        )
        let initialGrabPoint = initialGeometry.grabPoint(
            surfaceFraction: grabFraction,
            localOffset: .zero
        )
        var previousGrabPoint = initialGrabPoint
        var previousTip = initialGeometry.pointOnSurface(fraction: 1)
        var previousCenter = initialCenter

        for step in 1...241 {
            let translation = CGSize(width: CGFloat(step) * 2, height: 0)
            let desiredPoint = CGPoint(
                x: initialGrabPoint.x + translation.width,
                y: initialGrabPoint.y
            )
            let center = ElasticPlaybackControlBarGeometry.centerTracking(
                desiredPoint: desiredPoint,
                surfaceFraction: grabFraction,
                initialCenter: ElasticPlaybackControlBarGeometry.movedCenter(
                    from: previousCenter,
                    translation: CGSize(width: 2, height: 0)
                ),
                containerSize: size,
                utilityCount: 7,
                bendDirection: .up,
                maximumCorrection: 4
            )
            let geometry = ElasticPlaybackControlBarGeometry(
                containerSize: size,
                center: center,
                utilityCount: 7,
                bendDirection: .up
            )
            let grabPoint = geometry.grabPoint(
                surfaceFraction: grabFraction,
                localOffset: .zero
            )
            let tip = geometry.pointOnSurface(fraction: 1)

            #expect(hypot(
                grabPoint.x - previousGrabPoint.x,
                grabPoint.y - previousGrabPoint.y
            ) < 8, "grab point jumped at drag step \(step)")
            #expect(
                hypot(tip.x - previousTip.x, tip.y - previousTip.y) < 12,
                "tip jumped at drag step \(step)"
            )
            previousGrabPoint = grabPoint
            previousTip = tip
            previousCenter = center
        }
    }

    @Test func timelineDragIntentMovesAwayFromTheBarAndScrubsAlongIt() {
        let geometry = ElasticPlaybackControlBarGeometry(
            containerSize: CGSize(width: 1_000, height: 720),
            center: CGPoint(x: 500, y: 676),
            utilityCount: 7,
            bendDirection: .up
        )

        #expect(geometry.timelineDragPrefersMoving(
            translation: CGSize(width: 3, height: -3),
            fraction: 0.5
        ) == nil)
        #expect(geometry.timelineDragPrefersMoving(
            translation: CGSize(width: 24, height: 2),
            fraction: 0.5
        ) == false)
        #expect(geometry.timelineDragPrefersMoving(
            translation: CGSize(width: 2, height: -24),
            fraction: 0.5
        ) == true)
    }

    @Test func fullyTurnedBarRebasesIntoTheNextEdgeOrientation() {
        let size = CGSize(width: 1_000, height: 720)
        let turned = ElasticPlaybackControlBarGeometry(
            containerSize: size,
            center: CGPoint(x: 1_190, y: 676),
            utilityCount: 7,
            bendDirection: .up,
            orientation: .right
        )
        let rebasedCenter = turned.point(at: 0)
        let nextDirection = ElasticPlaybackControlBarGeometry.preferredBendDirection(
            at: rebasedCenter,
            in: size,
            orientation: turned.terminalOrientation
        )
        let rebased = ElasticPlaybackControlBarGeometry(
            containerSize: size,
            center: rebasedCenter,
            utilityCount: 7,
            bendDirection: nextDirection,
            orientation: turned.terminalOrientation
        )

        #expect(turned.bendProgress > 0.995)
        #expect(turned.terminalOrientation == .up)
        #expect(rebased.bendProgress < 0.08)
        #expect(hypot(
            turned.pointOnSurface(fraction: 0).x - rebased.pointOnSurface(fraction: 0).x,
            turned.pointOnSurface(fraction: 0).y - rebased.pointOnSurface(fraction: 0).y
        ) < 3)
        #expect(hypot(
            turned.pointOnSurface(fraction: 1).x - rebased.pointOnSurface(fraction: 1).x,
            turned.pointOnSurface(fraction: 1).y - rebased.pointOnSurface(fraction: 1).y
        ) < 3)
    }

    @Test func fourQuarterTurnsReturnToTheStartingOrientation() {
        var orientation = ElasticPlaybackControlBarOrientation.right
        orientation = orientation.turned(quarterTurns: -1)
        #expect(orientation == .up)
        orientation = orientation.turned(quarterTurns: -1)
        #expect(orientation == .left)
        orientation = orientation.turned(quarterTurns: -1)
        #expect(orientation == .down)
        orientation = orientation.turned(quarterTurns: -1)
        #expect(orientation == .right)
    }

    @Test func tipCanBendAlongASideWithoutSnappingToACorner() {
        let size = CGSize(width: 1_000, height: 720)
        let sideCenter = CGPoint(x: 700, y: 360)
        let geometry = ElasticPlaybackControlBarGeometry(
            containerSize: size,
            center: sideCenter,
            utilityCount: 7,
            bendDirection: .up
        )

        #expect(geometry.bendProgress > 0)
        #expect(abs(
            geometry.surfaceBounds.maxX
                - (size.width - ElasticPlaybackControlBarGeometry.horizontalInset)
        ) < 0.5, "the bent tip should remain attached to the contacted side")
        #expect(abs(
            geometry.point(at: 0).y - sideCenter.y
        ) < 0.5, "side contact must not pull the L toward either corner")
    }

    @Test func partialLRemainsContainedAsMagneticAttachmentReleases() {
        let size = CGSize(width: 1_200, height: 720)
        let contactedEdge = size.width
            - ElasticPlaybackControlBarGeometry.horizontalInset

        let weakBend = ElasticPlaybackControlBarGeometry(
            containerSize: size,
            center: CGPoint(x: 750, y: 360),
            utilityCount: 7,
            bendDirection: .up
        )
        let strongBend = ElasticPlaybackControlBarGeometry(
            containerSize: size,
            center: CGPoint(x: 900, y: 360),
            utilityCount: 7,
            bendDirection: .up
        )

        #expect(weakBend.bendProgress > 0)
        #expect(ElasticPlaybackControlBarGeometry.edgeAttachmentStrength(
            for: weakBend.bendProgress
        ) == 0)
        #expect(weakBend.surfaceBounds.maxX <= contactedEdge)
        #expect(strongBend.bendProgress >= 0.20)
        #expect(abs(strongBend.surfaceBounds.maxX - contactedEdge) < 0.5)
        #expect(abs(
            strongBend.point(at: 0).y - 360
        ) < 0.5, "edge attachment must not pull the L toward a corner")

        let detachedStraight = ElasticPlaybackControlBarGeometry(
            containerSize: size,
            center: CGPoint(x: 600, y: 360),
            utilityCount: 7,
            bendDirection: .up
        )
        #expect(detachedStraight.bendProgress == 0)
        #expect(detachedStraight.surfaceBounds.maxX < contactedEdge - 40)
    }

    @Test func forwardDragFeedsAPartialBendAtTheNextBoundary() throws {
        let size = CGSize(width: 1_000, height: 720)
        let center = CGPoint(x: 650, y: 50)
        let geometry = ElasticPlaybackControlBarGeometry(
            containerSize: size,
            center: center,
            utilityCount: 7,
            bendDirection: .up
        )
        let advancedCenter = try #require(
            geometry.centerAdvancingBendAtTerminalBoundary(
                translation: CGSize(width: 0, height: -3)
            )
        )
        let advanced = ElasticPlaybackControlBarGeometry(
            containerSize: size,
            center: advancedCenter,
            utilityCount: 7,
            bendDirection: .up
        )

        #expect(geometry.bendProgress > 0 && geometry.bendProgress < 0.995)
        #expect(abs(
            geometry.surfaceBounds.minY - ElasticPlaybackControlBarGeometry.topInset
        ) < 0.5)
        #expect(advancedCenter.x > center.x)
        #expect(advancedCenter.y == center.y)
        #expect(advanced.bendProgress > geometry.bendProgress)
        #expect(geometry.centerAdvancingBendAtTerminalBoundary(
            translation: CGSize(width: 0, height: 3)
        ) == nil, "reverse travel should remain ordinary pointer tracking")
    }
}

@Suite("Sources sidebar mount policy")
struct SourcesSidebarMountPolicyTests {
    @Test func shellTracksExplicitSidebarVisibility() {
        #expect(SourcesSidebarMountPolicy.shouldMountShell(isSidebarVisible: true))
        #expect(!SourcesSidebarMountPolicy.shouldMountShell(isSidebarVisible: false))
    }

    @Test func explicitSidebarKeepsFolderTreeMountedAcrossChromeHides() {
        #expect(SourcesSidebarMountPolicy.shouldMountContent(
            isSidebarVisible: true
        ))
        #expect(!SourcesSidebarMountPolicy.shouldMountContent(
            isSidebarVisible: false
        ))
    }

    @Test func stateSurvivesIndependentMountDecisions() {
        var state = SourcesSidebarState()
        state.searchText = "episode"
        state.expandedFolderIDs = ["/media/shows"]
        state.knownSourceFolderIDs = ["/media"]
        state.hasInitializedExpansion = true

        #expect(SourcesSidebarMountPolicy.shouldMountContent(
            isSidebarVisible: true
        ))
        #expect(state.searchText == "episode")
        #expect(state.expandedFolderIDs == ["/media/shows"])
        #expect(state.knownSourceFolderIDs == ["/media"])
        #expect(state.hasInitializedExpansion)
    }

    @Test func startsWithAnUnfilteredUninitializedTree() {
        let state = SourcesSidebarState()

        #expect(state.searchText.isEmpty)
        #expect(state.expandedFolderIDs.isEmpty)
        #expect(state.knownSourceFolderIDs.isEmpty)
        #expect(!state.hasInitializedExpansion)
    }
}

@Suite("Sources sidebar sizing")
struct SourcesSidebarSizingTests {
    @Test func narrowWindowsDisableTheSidebarAtTheCutoff() {
        #expect(!SourcesSidebarSizing.isAvailable(in: 720))
        #expect(!SourcesSidebarSizing.isAvailable(in: 899.5))
        #expect(SourcesSidebarSizing.isAvailable(in: 900))
        #expect(SourcesSidebarSizing.isAvailable(in: 1200))
    }

    @Test func draggingRightExpandsAndDraggingLeftContracts() {
        #expect(SourcesSidebarSizing.resolvedWidth(
            storedWidth: 360,
            dragTranslation: 120,
            maximumWidth: 700
        ) == 480)
        #expect(SourcesSidebarSizing.resolvedWidth(
            storedWidth: 480,
            dragTranslation: -80,
            maximumWidth: 700
        ) == 400)
        #expect(SourcesSidebarSizing.settledWidth(
            storedWidth: 360,
            maximumWidth: 700
        ) == 360)
    }

    @Test func sidebarWidthStaysUsefulAtBothBounds() {
        #expect(SourcesSidebarSizing.resolvedWidth(
            storedWidth: 360,
            dragTranslation: -500,
            maximumWidth: 700
        ) == SourcesSidebarSizing.minimumWidth)
        #expect(SourcesSidebarSizing.resolvedWidth(
            storedWidth: 360,
            dragTranslation: 900,
            maximumWidth: 620
        ) == 620)
        #expect(SourcesSidebarSizing.maximumWidth(for: 1_200) == 720)
        #expect(SourcesSidebarSizing.maximumWidth(for: 800) == 448)
    }

    @Test func sidebarLeavesPlaybackChromeUncovered() {
        #expect(SourcesSidebarLayoutPolicy.occupiedWidth(
            forSidebarWidth: 360
        ) == 380)
        #expect(
            800
                - SourcesSidebarLayoutPolicy.occupiedWidth(
                    forSidebarWidth: SourcesSidebarSizing.maximumWidth(
                        for: 800
                    )
                )
                == SourcesSidebarLayoutPolicy.minimumUncoveredChromeWidth
        )
    }

    @Test @MainActor
    func folderScrollerUsesTheThinNativeOverlayStyle() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy

        SourcesSidebarScrollerStyle.apply(to: scrollView)

        #expect(scrollView.scrollerStyle == .overlay)
        #expect(scrollView.autohidesScrollers)
        #expect(!scrollView.hasHorizontalScroller)
        #expect(scrollView.verticalScroller?.controlSize == .mini)
    }
}

@Suite("Sources sidebar resize layout")
@MainActor
struct SourcesSidebarResizeLayoutTests {
    @Test func repeatedLiveWidthsKeepTheLazyFolderTreeStable() {
        let host = NSHostingView(
            rootView: SourcesSidebarResizeLayoutFixture(
                liveWidth: 672
            )
        )
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        host.layoutSubtreeIfNeeded()

        let widths = Array(stride(from: 672, through: 280, by: -8))
            + Array(stride(from: 280, through: 672, by: 8))

        for _ in 0..<8 {
            for width in widths {
                host.rootView = SourcesSidebarResizeLayoutFixture(
                    liveWidth: CGFloat(width)
                )
                host.layoutSubtreeIfNeeded()
            }
        }

        #expect(host.frame.size == NSSize(width: 900, height: 700))
    }
}

private struct SourcesSidebarResizeLayoutFixture: View {
    let liveWidth: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter folders", text: .constant(""))
                .padding(12)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(0..<100, id: \.self) { index in
                        Text("Folder item \(index)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 7)
                    }
                }
            }
        }
        .frame(width: liveWidth, height: 640)
    }
}

@Suite("Sources sidebar folder model")
struct SourcesSidebarFolderModelTests {
    @Test func sourceFolderPersistenceIgnoresMalformedAndDuplicateEntries() {
        let result = SourceFolderLibrary.restore(from: [
            "/media/shows",
            42,
            "",
            "/media/shows/../shows",
            "/media/movies",
        ])

        #expect(result.map(\.path) == ["/media/shows", "/media/movies"])
    }

    @Test func legacyFoldersMigrateToWorkspaceTabsAndRestoreSelection() {
        let folders = [
            URL(fileURLWithPath: "/media/shows", isDirectory: true),
            URL(fileURLWithPath: "/media/movies", isDirectory: true),
        ]
        let tabs = SourceTabs.migrating(folders)

        #expect(tabs.map(\.displayName) == ["shows", "movies"])
        #expect(tabs.map(\.items) == [
            [SourceTabItem(kind: .folder, url: folders[0])],
            [SourceTabItem(kind: .folder, url: folders[1])],
        ])
        #expect(
            SourceTabs.resolvedSelection(nil, in: tabs)
                == SourceTabs.migratedTabID(forFolderID: "/media/shows")
        )
        #expect(
            SourceTabs.resolvedSelection(
                SourceTabs.migratedTabID(forFolderID: "/media/movies"),
                in: tabs
            ) == SourceTabs.migratedTabID(forFolderID: "/media/movies")
        )
        #expect(
            SourceTabs.resolvedSelection("missing", in: tabs)
                == SourceTabs.migratedTabID(forFolderID: "/media/shows")
        )
        #expect(
            SourceTabs.activeTab(
                selectedID: SourceTabs.migratedTabID(
                    forFolderID: "/media/movies"
                ),
                in: tabs
            ) == tabs[1]
        )
    }

    @Test func emptyWorkspaceTabRenamesFromItsFirstFolderOrFile() {
        let empty = SourceTab(id: "empty", items: [])
        let files = SourceTab(
            id: "files",
            items: [
                SourceTabItem(
                    kind: .file,
                    url: URL(fileURLWithPath: "/media/Opening.mkv")
                ),
            ]
        )
        let mixed = SourceTab(
            id: "mixed",
            items: [
                SourceTabItem(
                    kind: .file,
                    url: URL(fileURLWithPath: "/media/Opening.mkv")
                ),
                SourceTabItem(
                    kind: .folder,
                    url: URL(fileURLWithPath: "/media/Shows", isDirectory: true)
                ),
            ]
        )

        #expect(empty.displayName == "New Tab")
        #expect(files.displayName == "Opening")
        #expect(mixed.displayName == "Shows")
    }

    @Test func workspaceItemsMergeMultipleFilesAndFoldersWithoutDuplicates() {
        let movie = URL(fileURLWithPath: "/media/Movie.mkv")
        let shows = URL(fileURLWithPath: "/media/Shows", isDirectory: true)
        let items = SourceTabItems.merging(
            SourceTabItems.merging([], with: [movie, movie], kind: .file),
            with: [shows, shows],
            kind: .folder
        )

        #expect(items == [
            SourceTabItem(kind: .file, url: movie),
            SourceTabItem(kind: .folder, url: shows),
        ])
    }

    @Test func closingTheActiveWorkspaceTabSelectsItsNearestNeighbor() {
        let tabs = [
            SourceTab(id: "one", items: []),
            SourceTab(id: "two", items: []),
            SourceTab(id: "three", items: []),
        ]

        #expect(
            SourceTabs.selectionAfterClosing(
                "two",
                selectedID: "two",
                from: tabs
            ) == "three"
        )
        #expect(
            SourceTabs.selectionAfterClosing(
                "three",
                selectedID: "three",
                from: tabs
            ) == "two"
        )
        #expect(
            SourceTabs.selectionAfterClosing(
                "one",
                selectedID: "two",
                from: tabs
            ) == "two"
        )
    }

    @Test func workspaceTabNavigationWrapsInBothDirections() {
        let tabs = [
            SourceTab(id: "one", items: []),
            SourceTab(id: "two", items: []),
            SourceTab(id: "three", items: []),
        ]

        #expect(
            SourceTabs.adjacentSelection(
                from: "three",
                direction: .next,
                in: tabs
            ) == "one"
        )
        #expect(
            SourceTabs.adjacentSelection(
                from: "one",
                direction: .previous,
                in: tabs
            ) == "three"
        )
    }

    @Test func playingIndicatorMatchesFilesAndFoldersInsideAWorkspaceTab() {
        let tab = SourceTab(
            id: "mixed",
            items: [
                SourceTabItem(
                    kind: .file,
                    url: URL(fileURLWithPath: "/media/Movie.mkv")
                ),
                SourceTabItem(
                    kind: .folder,
                    url: URL(fileURLWithPath: "/media/shows", isDirectory: true)
                ),
            ]
        )

        #expect(SourceTabs.contains(
            URL(fileURLWithPath: "/media/Movie.mkv"),
            in: tab
        ))
        #expect(SourceTabs.contains(
            URL(fileURLWithPath: "/media/shows/Season 1/Episode.mkv"),
            in: tab
        ))
        #expect(!SourceTabs.contains(
            URL(fileURLWithPath: "/media/shows-archive/Episode.mkv"),
            in: tab
        ))
        #expect(!SourceTabs.contains(
            URL(string: "https://example.com/Episode.mkv")!,
            in: tab
        ))
    }

    @Test func workspaceTabsRoundTripThroughPersistence() {
        let tabs = [
            SourceTab(id: "empty", items: []),
            SourceTab(
                id: "mixed",
                items: [
                    SourceTabItem(
                        kind: .file,
                        url: URL(fileURLWithPath: "/media/Movie.mkv")
                    ),
                    SourceTabItem(
                        kind: .folder,
                        url: URL(
                            fileURLWithPath: "/media/Shows",
                            isDirectory: true
                        )
                    ),
                ]
            ),
        ]

        let data = SourceTabStore.encode(tabs)
        #expect(data != nil)
        #expect(SourceTabStore.restore(from: data) == tabs)
        #expect(SourceTabStore.restore(from: Data("bad".utf8)) == nil)

        let duplicateData = SourceTabStore.encode([
            SourceTab(id: "same", items: []),
            SourceTab(
                id: "same",
                items: [
                    SourceTabItem(
                        kind: .file,
                        url: URL(fileURLWithPath: "/media/Ignored.mkv")
                    ),
                ]
            ),
        ])
        #expect(SourceTabStore.restore(from: duplicateData) == [
            SourceTab(id: "same", items: []),
        ])
    }

    @Test func directoryLoaderFindsFoldersAndSupportedVideos() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlatinumSources-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Season 2", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data().write(to: root.appendingPathComponent("Episode 10.mkv"))
        try Data().write(to: root.appendingPathComponent("Episode 2.mkv"))
        try Data().write(to: root.appendingPathComponent("notes.txt"))

        let listing = SourceDirectoryLoader.read(root)
        let entries = SourceTreeSorting.sorted(
            listing.entries,
            using: SourceTreeSortConfiguration(
                name: .ascending,
                dateCreated: .off,
                type: .ascending
            )
        )

        #expect(listing.errorMessage == nil)
        #expect(entries.map(\.url.lastPathComponent) == [
            "Season 2",
            "Episode 2.mkv",
            "Episode 10.mkv",
        ])
        #expect(entries.map(\.kind) == [.folder, .media, .media])
        #expect(entries.allSatisfy { entry in
            entry.visibilityPath == SourceVisibilityPath.normalized(entry.url)
        })
    }

    @Test func folderContentsCombineTriStateSortCriteria() {
        let olderVideo = SourceTreeEntry(
            url: URL(fileURLWithPath: "/media/Episode 10.mkv"),
            kind: .media,
            dateAdded: nil,
            creationDate: Date(timeIntervalSince1970: 100)
        )
        let newerVideo = SourceTreeEntry(
            url: URL(fileURLWithPath: "/media/Episode 2.mkv"),
            kind: .media,
            dateAdded: nil,
            creationDate: Date(timeIntervalSince1970: 300)
        )
        let middleFolder = SourceTreeEntry(
            url: URL(fileURLWithPath: "/media/Season 1", isDirectory: true),
            kind: .folder,
            dateAdded: nil,
            creationDate: Date(timeIntervalSince1970: 200)
        )
        let entries = [olderVideo, middleFolder, newerVideo]

        #expect(
            SourceTreeSorting.sorted(
                entries,
                using: SourceTreeSortConfiguration(
                    name: .ascending,
                    dateCreated: .off,
                    type: .off
                )
            )
                .map(\.url.lastPathComponent)
                == ["Episode 2.mkv", "Episode 10.mkv", "Season 1"]
        )
        #expect(
            SourceTreeSorting.sorted(
                entries,
                using: SourceTreeSortConfiguration(
                    name: .off,
                    dateCreated: .descending,
                    type: .off
                )
            )
                .map(\.url.lastPathComponent)
                == ["Episode 2.mkv", "Season 1", "Episode 10.mkv"]
        )
        #expect(
            SourceTreeSorting.sorted(
                entries,
                using: SourceTreeSortConfiguration(
                    name: .ascending,
                    dateCreated: .off,
                    type: .ascending
                )
            )
                .map(\.url.lastPathComponent)
                == ["Season 1", "Episode 2.mkv", "Episode 10.mkv"]
        )
        #expect(
            SourceTreeSorting.sorted(
                entries,
                using: SourceTreeSortConfiguration(
                    name: .off,
                    dateCreated: .descending,
                    type: .descending
                )
            )
                .map(\.url.lastPathComponent)
                == ["Episode 2.mkv", "Episode 10.mkv", "Season 1"]
        )
        #expect(
            SourceTreeSorting.sorted(
                entries,
                using: SourceTreeSortConfiguration(
                    name: .off,
                    dateCreated: .off,
                    type: .off
                )
            ) == entries
        )
    }

    @Test func sortDirectionCyclesOffAscendingDescending() {
        #expect(SourceTreeSortDirection.off.next == .ascending)
        #expect(SourceTreeSortDirection.ascending.next == .descending)
        #expect(SourceTreeSortDirection.descending.next == .off)
        #expect(SourceTreeSortDirection.resolve("unsupported") == .off)
    }

    @Test func expansionPersistenceRetainsCollapsedRootsAcrossLaunches() {
        let suiteName = "SourcesSidebarExpansion-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let snapshot = SourcesSidebarExpansionSnapshot(
            expandedFolderIDs: ["/media/shows/season-1"],
            knownSourceFolderIDs: ["/media/shows", "/media/movies"]
        )

        SourcesSidebarExpansionStore.persist(snapshot, defaults: defaults)
        let restored = SourcesSidebarState.restored(defaults: defaults)

        #expect(restored.expandedFolderIDs == ["/media/shows/season-1"])
        #expect(restored.knownSourceFolderIDs == ["/media/shows", "/media/movies"])
        #expect(!restored.expandedFolderIDs.contains("/media/movies"))
        #expect(restored.hasInitializedExpansion)
    }

    @Test func malformedExpansionPersistenceCannotPreventLaunch() {
        #expect(SourcesSidebarExpansionStore.restore(from: Data("not-json".utf8)) == nil)

        let malformedPaths = """
        {
          "version": 1,
          "expandedFolderIDs": ["relative/path", "/media/shows/../shows"],
          "knownSourceFolderIDs": ["/media", 42]
        }
        """
        #expect(SourcesSidebarExpansionStore.restore(
            from: Data(malformedPaths.utf8)
        ) == nil)
    }

    @Test func legacyWorkspaceTabsDecodeWithoutVisibilityConfiguration() {
        let legacy = """
        [
          {
            "id": "legacy",
            "items": [
              {"kind": "folder", "path": "/media/shows"}
            ]
          }
        ]
        """

        #expect(SourceTabStore.restore(from: Data(legacy.utf8)) == [
            SourceTab(
                id: "legacy",
                items: [
                    SourceTabItem(
                        kind: .folder,
                        url: URL(
                            fileURLWithPath: "/media/shows",
                            isDirectory: true
                        )
                    ),
                ]
            ),
        ])
    }

    @Test func workspaceVisibilityConfigurationRoundTripsAndNormalizes() {
        let visibility = SourceVisibilityConfiguration(
            viewMode: .filesOnly,
            showsHiddenItems: true,
            manuallyHiddenPaths: ["/media/shows/../shows/Extras"],
            alwaysShownPaths: ["/media/shows/Movie.mkv"],
            regexRules: [
                SourceVisibilityRegexRule(
                    id: "extras",
                    pattern: #"(?i)(^|/)extras(/|$)"#,
                    colorIndex: 3,
                    isEnabled: true
                ),
            ]
        )
        let tab = SourceTab(
            id: "filtered",
            items: [],
            visibility: visibility
        )

        let restored = SourceTabStore.restore(from: SourceTabStore.encode([tab]))

        #expect(restored?.first?.visibility?.viewMode == .filesOnly)
        #expect(restored?.first?.visibility?.showsHiddenItems == true)
        #expect(
            restored?.first?.visibility?.manuallyHiddenPaths
                == ["/media/shows/Extras"]
        )
        #expect(
            restored?.first?.visibility?.alwaysShownPaths
                == ["/media/shows/Movie.mkv"]
        )
        #expect(restored?.first?.visibility?.regexRules == visibility.regexRules)
    }

    @Test func visibilityMatcherCombinesManualRegexAndAlwaysShowRules() throws {
        let root = URL(fileURLWithPath: "/media/shows", isDirectory: true)
        let regexRule = SourceVisibilityRegexRule(
            id: "samples",
            pattern: #"(?i)(^|/)(sample|trailer)[^/]*\.mkv$"#,
            colorIndex: 2,
            isEnabled: true
        )
        let manualURL = root.appendingPathComponent("Season 1/Bonus.mkv")
        let allowedURL = root.appendingPathComponent("Trailers/Trailer.mkv")
        var configuration = SourceVisibilityConfiguration(
            viewMode: .tree,
            showsHiddenItems: false,
            manuallyHiddenPaths: [manualURL.path],
            alwaysShownPaths: [allowedURL.path],
            regexRules: [regexRule]
        )
        configuration.normalize()
        let matcher = SourceVisibilityMatcher(
            configuration: configuration,
            roots: [root]
        )

        let manual = matcher.evaluate(manualURL)
        let sample = matcher.evaluate(
            root.appendingPathComponent("Season 1/Sample Episode.mkv")
        )
        let allowed = matcher.evaluate(allowedURL)

        #expect(manual.hiddenMatches == [.manual])
        #expect(
            sample.hiddenMatches == [
                .regex(SourceVisibilityRegexMatch(id: "samples", colorIndex: 2)),
            ]
        )
        let samplePath = try #require(SourceVisibilityPath.normalized(
            root.appendingPathComponent("Season 1/Sample Episode.mkv")
        ))
        #expect(matcher.evaluate(normalizedPath: samplePath) == sample)
        #expect(allowed.hiddenMatches.isEmpty)
        #expect(allowed.regexMatches.map(\.id) == ["samples"])
        #expect(
            matcher.relativePath(for: manualURL)
                == "Season 1/Bonus.mkv"
        )
    }

    @Test func filesOnlyVisibilityInheritsHiddenFolderRules() {
        let root = URL(fileURLWithPath: "/media/shows", isDirectory: true)
        let extras = root.appendingPathComponent(
            "Extras",
            isDirectory: true
        )
        let child = extras.appendingPathComponent("Featurette.mkv")
        var configuration = SourceVisibilityConfiguration(
            viewMode: .filesOnly,
            showsHiddenItems: false,
            manuallyHiddenPaths: [extras.path],
            alwaysShownPaths: [child.path],
            regexRules: []
        )
        configuration.normalize()
        let matcher = SourceVisibilityMatcher(
            configuration: configuration,
            roots: [root]
        )

        #expect(matcher.evaluate(child).hiddenMatches.isEmpty)
        #expect(
            matcher.evaluateIncludingAncestors(child).hiddenMatches == [.manual]
        )
    }

    @Test func visibilityConfigurationDropsUnsafeOrMalformedRules() {
        var configuration = SourceVisibilityConfiguration(
            viewMode: .tree,
            showsHiddenItems: false,
            manuallyHiddenPaths: ["relative/file.mkv", "/media/valid.mkv"],
            alwaysShownPaths: ["/media/valid.mkv", "/media/always.mkv"],
            regexRules: [
                SourceVisibilityRegexRule(
                    id: "valid",
                    pattern: "sample",
                    colorIndex: 99,
                    isEnabled: true
                ),
                SourceVisibilityRegexRule(
                    id: "duplicate",
                    pattern: "sample",
                    colorIndex: 1,
                    isEnabled: true
                ),
                SourceVisibilityRegexRule(
                    id: "invalid",
                    pattern: "[",
                    colorIndex: 1,
                    isEnabled: true
                ),
            ]
        )

        configuration.normalize()

        #expect(configuration.manuallyHiddenPaths == ["/media/valid.mkv"])
        #expect(configuration.alwaysShownPaths == ["/media/always.mkv"])
        #expect(configuration.regexRules.count == 1)
        #expect(configuration.regexRules.first?.colorIndex == 5)
    }

    @Test func sourceViewModesProjectTheExpectedKinds() {
        #expect(SourceVisibilityProjection.includes(.folder, in: .tree))
        #expect(SourceVisibilityProjection.includes(.media, in: .tree))
        #expect(!SourceVisibilityProjection.includes(.folder, in: .filesOnly))
        #expect(SourceVisibilityProjection.includes(.media, in: .filesOnly))
        #expect(SourceVisibilityProjection.includes(.folder, in: .foldersOnly))
        #expect(!SourceVisibilityProjection.includes(.media, in: .foldersOnly))
    }

    @Test func recursiveFilesOnlyLoaderFindsNestedSupportedMedia() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PlatinumRecursiveSources-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Season 1", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".Hidden", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data().write(
            to: root.appendingPathComponent("Season 1/Episode.mkv")
        )
        try Data().write(to: root.appendingPathComponent("Movie.mp4"))
        try Data().write(to: root.appendingPathComponent("notes.txt"))
        try Data().write(
            to: root.appendingPathComponent(".Hidden/Secret.mkv")
        )

        let entries = SourceRecursiveMediaLoader.read([root])

        #expect(Set(entries.map(\.url.lastPathComponent)) == [
            "Episode.mkv",
            "Movie.mp4",
        ])
        #expect(entries.allSatisfy { $0.visibilityPath != nil })
    }
}

@Suite("Window aspect lock sizing")
struct WindowAspectLockSizingTests {
    @Test func removesLetterboxingUsingTheNearestWindowDimension() {
        let result = WindowAspectLockSizing.fittedContentSize(
            currentSize: CGSize(width: 1_263, height: 768),
            minimumSize: CGSize(width: 720, height: 440),
            aspectRatio: 16.0 / 9.0
        )

        #expect(result == CGSize(width: 1_263, height: 710.4375))
    }

    @Test func preservesMinimumSizeWhileKeepingTheVideoAspect() {
        let result = WindowAspectLockSizing.fittedContentSize(
            currentSize: CGSize(width: 720, height: 440),
            minimumSize: CGSize(width: 720, height: 440),
            aspectRatio: 16.0 / 9.0
        )

        #expect(result == CGSize(width: 782.2222222222222, height: 440))
    }
}
