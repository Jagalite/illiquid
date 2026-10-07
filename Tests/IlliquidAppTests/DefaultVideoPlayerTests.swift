import Foundation
import Testing
import UniformTypeIdentifiers
@testable import IlliquidApp

@Suite("Default video player")
@MainActor
struct DefaultVideoPlayerTests {
    let app = URL(fileURLWithPath: "/Applications/Illiquid.app")

    @Test func offersOncePerLaunchAndAgainOnNextLaunch() throws {
        let suite = "DefaultVideoPlayerTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // The old one-time prompt answer must not disable the new launch reminder.
        defaults.set(true, forKey: "Illiquid.defaultVideoPlayer.promptAnswered")
        func launch() -> DefaultVideoPlayer {
            DefaultVideoPlayer(applicationURL: app, extensions: ["mp4"],
                defaults: defaults, currentApplication: { _ in nil },
                setApplication: { _, _ in Issue.record("Offering must not change associations") })
        }
        let first = launch()
        #expect(first.asksOnLaunch)
        #expect(first.takeLaunchOffer())
        #expect(!first.takeLaunchOffer())
        #expect(launch().takeLaunchOffer())
    }

    @Test func disablingReminderPersistsAndManualActionStillWorks() async throws {
        let suite = "DefaultVideoPlayerTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var handler: URL?
        func launch() -> DefaultVideoPlayer {
            DefaultVideoPlayer(applicationURL: app, extensions: ["mp4"],
                defaults: defaults, currentApplication: { _ in handler },
                setApplication: { url, _ in handler = url })
        }
        launch().asksOnLaunch = false
        let next = launch()
        #expect(!next.asksOnLaunch)
        #expect(!next.takeLaunchOffer())
        await next.makeDefault()
        #expect(handler == app)
        #expect(!next.asksOnLaunch)
        next.asksOnLaunch = true
        #expect(!launch().takeLaunchOffer()) // Already the default.
        handler = nil
        #expect(launch().takeLaunchOffer()) // Another app took over.
    }

    @Test func sharedTypesAreChangedOnceAndVerified() async {
        let suite = "DefaultVideoPlayerTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var handler: URL?
        var calls = 0
        let controller = DefaultVideoPlayer(applicationURL: app, extensions: ["mp4", "m4v"],
            defaults: defaults,
            resolve: { _ in .mpeg4Movie }, currentApplication: { _ in handler },
            setApplication: { url, _ in calls += 1; handler = url })
        await controller.makeDefault()
        #expect(calls == 1)
        #expect(controller.result?.contains("all supported") == true)
        #expect(!controller.isChanging)
    }

    @Test func unconfirmedAndUnresolvedFormatsAreReported() async {
        let suite = "DefaultVideoPlayerTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = DefaultVideoPlayer(applicationURL: app, extensions: ["mp4", "unknown"],
            defaults: defaults, resolve: { $0 == "mp4" ? .mpeg4Movie : nil },
            currentApplication: { _ in nil }, setApplication: { _, _ in })
        await controller.makeDefault()
        #expect(controller.result?.contains("MP4, UNKNOWN") == true)
        #expect(controller.result?.contains("now the default") == false)
    }

    @Test func diskImageCopyDoesNotPromptOrChangeAssociations() async {
        let controller = DefaultVideoPlayer(
            applicationURL: URL(fileURLWithPath: "/Volumes/Illiquid/Illiquid.app"),
            extensions: ["mp4"], currentApplication: { _ in nil },
            setApplication: { _, _ in Issue.record("DMG copy must not become default") })
        #expect(!controller.shouldOffer)
        await controller.makeDefault()
        #expect(controller.result?.contains("Move Illiquid") == true)
    }

    @Test func permissionFailureIsReportedAndCanBeRetried() async {
        let suite = "DefaultVideoPlayerTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var handler: URL?
        var deny = true
        let controller = DefaultVideoPlayer(applicationURL: app, extensions: ["mp4"],
            defaults: defaults, currentApplication: { _ in handler },
            setApplication: { url, _ in
                if deny { throw CocoaError(.fileWriteNoPermission) }
                handler = url
            })
        await controller.makeDefault()
        #expect(controller.result?.contains("Could not") == true)
        deny = false
        await controller.makeDefault()
        #expect(controller.result?.contains("all supported") == true)
    }

    @Test(arguments: [0, 1, 2])
    func cancellationStopsFurtherRequestsAndAllowsRetry(kind: Int) async {
        let suite = "DefaultVideoPlayerTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var handlers: [String: URL] = [:]
        var requests: [String] = []
        var cancel = true
        let controller = DefaultVideoPlayer(applicationURL: app, extensions: ["mp4", "mov", "avi"],
            defaults: defaults, currentApplication: { handlers[$0.identifier] },
            setApplication: { url, type in
                requests.append(type.identifier)
                if cancel && type == .quickTimeMovie {
                    switch kind {
                    case 0: throw CocoaError(.userCancelled)
                    case 1: throw NSError(domain: NSOSStatusErrorDomain, code: -128)
                    default: throw CancellationError()
                    }
                }
                handlers[type.identifier] = url
            })
        await controller.makeDefault()
        #expect(requests == [UTType.mpeg4Movie.identifier, UTType.quickTimeMovie.identifier])
        #expect(handlers[UTType.mpeg4Movie.identifier] == app)
        #expect(controller.result?.contains("cancelled") == true)
        #expect(!controller.isChanging)
        cancel = false
        requests.removeAll()
        await controller.makeDefault()
        #expect(requests == [UTType.quickTimeMovie.identifier, UTType.avi.identifier])
        #expect(controller.result?.contains("all supported") == true)
    }

    @Test func transportStreamResolutionStaysWithinMovieTypes() async {
        var requestedType: UTType?
        let controller = DefaultVideoPlayer(applicationURL: app, extensions: ["ts"],
            currentApplication: { _ in nil },
            setApplication: { _, type in requestedType = type })
        await controller.makeDefault()
        #expect(requestedType?.conforms(to: .movie) == true)
        #expect(requestedType?.identifier != "com.microsoft.typescript")
    }

    @Test func nonVideoResolutionNeverChangesAnAssociation() async {
        let controller = DefaultVideoPlayer(applicationURL: app, extensions: ["ts"],
            resolve: { _ in .sourceCode }, currentApplication: { _ in nil },
            setApplication: { _, _ in Issue.record("Must not change source-code associations") })
        await controller.makeDefault()
        #expect(controller.result?.contains("Could not") == true)
    }

}
