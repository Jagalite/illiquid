import Foundation
import Testing
@testable import IlliquidCore

@Suite("Thumbnail scheduling policy")
struct ThumbnailPolicyTests {
    @Test func storyboardAndLocalCoverageStayBoundedAndValid() throws {
        for duration in [0.2, 30, 7_200] {
            let broad = ThumbnailPolicy.storyboard(duration: duration)
            #expect(!broad.isEmpty && broad.count <= 24 && Set(broad).count == broad.count)
            #expect(broad.allSatisfy { $0 >= 0 && $0 < duration })
            for focus in [0.0, min(32.4, duration), duration / 2, duration] {
                let local = ThumbnailPolicy.nearby(duration: duration, focus: focus)
                #expect(local.count <= 13 && Set(local).count == local.count)
                #expect(local.allSatisfy { $0 >= 0 && $0 < duration && abs($0 - focus) <= 30 })
            }
        }
        #expect(ThumbnailPolicy.storyboard(duration: .nan).isEmpty)
        #expect(ThumbnailPolicy.nearby(duration: 20, focus: .infinity).isEmpty)
        let settings = try JSONDecoder().decode(ThumbnailPreferences.self, from: Data("{}".utf8))
        #expect(settings.preparesCurrentVideo && !settings.generatesInBackground)
        #expect(settings.memoryMiB == 16)
        var disabled = settings; disabled.preparesCurrentVideo = false
        #expect(try JSONDecoder().decode(ThumbnailPreferences.self, from: JSONEncoder().encode(disabled)) == disabled)
    }

    @Test func oldPreferencesKeepTheirBudgetsWhenExclusionsAreAdded() throws {
        let data = Data(#"{"memoryMiB":64,"diskMiB":0,"generatesInBackground":true,"priority":"recent"}"#.utf8)
        let settings = try JSONDecoder().decode(ThumbnailPreferences.self, from: data)
        #expect(settings.memoryMiB == 64 && settings.diskMiB == 0)
        #expect(settings.generatesInBackground && settings.priority == .recent)
        #expect(settings.excludedFolderPaths.isEmpty)
        #expect(try JSONDecoder().decode(ThumbnailPreferences.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test func presetsPreserveConsentAndExclusionsAndMatchPathBoundaries() {
        var settings = ThumbnailPreferences()
        settings.excludedFolderPaths = ["/media/slow", "/media/slow/../slow", "relative"]
        settings = settings.bounded
        #expect(settings.excludedFolderPaths == ["/media/slow"])
        for preset in ThumbnailPreferences.Preset.allCases {
            settings.apply(preset)
            #expect(!settings.generatesInBackground && !settings.generatesWithWindowClosed)
            #expect(settings.excludesBackgroundGeneration(for: URL(fileURLWithPath: "/media/slow/show/video.mkv")))
            #expect(!settings.excludesBackgroundGeneration(for: URL(fileURLWithPath: "/media/slowish/video.mkv")))
        }
        let blocked = URL(fileURLWithPath: "/media/slow/video.mkv")
        #expect(ThumbnailPolicy.ranked([.init(url: blocked, isVisible: true)], current: blocked,
            folder: nil, now: Date(), preferences: settings).isEmpty)
    }
    let now = Date(timeIntervalSince1970: 2_000_000)
    func url(_ path: String) -> URL { URL(fileURLWithPath: "/media/\(path)") }

    @Test func foregroundAndViewportCannotBeOvertakenByHistory() {
        let current = url("a/current.mkv"), visible = url("b/visible.mkv"), recent = url("a/recent.mkv")
        var settings = ThumbnailPreferences(); settings.priority = .recent
        let result = ThumbnailPolicy.ranked([
            .init(url: recent, lastUsed: now), .init(url: visible, isVisible: true), .init(url: current)
        ], current: current, folder: url("a"), now: now, preferences: settings)
        #expect(result == [current, visible, recent])
    }

    @Test func userPriorityChangesTheNextSpeculativeVideo() {
        let nearby = url("a/old.mkv"), recent = url("b/new.mkv")
        let candidates: [ThumbnailPolicy.Candidate] = [.init(url: nearby), .init(url: recent, lastUsed: now)]
        var settings = ThumbnailPreferences(); settings.priority = .nearby
        #expect(ThumbnailPolicy.ranked(candidates, current: nil, folder: url("a"), now: now, preferences: settings).first == nearby)
        settings.priority = .recent
        #expect(ThumbnailPolicy.ranked(candidates, current: nil, folder: url("a"), now: now, preferences: settings).first == recent)
    }

    @Test func navigationRetiresDistantUnseenFilesAndExpiresHistory() {
        let old = url("old/a.mkv"), new = url("new/b.mkv")
        let candidates: [ThumbnailPolicy.Candidate] = [
            .init(url: old, lastUsed: now.addingTimeInterval(-8 * 86400)), .init(url: new), .init(url: new)]
        #expect(ThumbnailPolicy.ranked(candidates, current: nil, folder: url("new"), now: now,
                                      preferences: .init()) == [new])
    }

    @Test func samplesAreUniqueBoundedAndStartAtInterest() {
        #expect(ThumbnailPolicy.samples(duration: .infinity, focus: 0, count: 12).isEmpty)
        #expect(ThumbnailPolicy.samples(duration: 0.1, focus: 99, count: 64) == [0])
        let samples = ThumbnailPolicy.samples(duration: 120, focus: 42.3, count: 12)
        #expect(samples.first == 42.5)
        #expect(samples.count == 12 && Set(samples).count == 12)
        #expect(samples.allSatisfy { $0 >= 0 && $0 < 120 })
        #expect(samples.prefix(4).contains(60))
    }

    @Test func malformedBudgetsAreClampedAndGenerationDefaultsOff() throws {
        var settings = ThumbnailPreferences()
        #expect(!settings.generatesInBackground && !settings.generatesWithWindowClosed)
        settings.memoryMiB = Int.max; settings.diskMiB = -1; settings.videosPerPass = Int.max
        settings.samplesPerVideo = -20; settings.workSeconds = Int.max
        let bounded = settings.bounded
        #expect(bounded.memoryMiB == 128 && bounded.diskMiB == 0)
        #expect(bounded.videosPerPass == 64 && bounded.samplesPerVideo == 1 && bounded.workSeconds == 120)
        #expect(try JSONDecoder().decode(ThumbnailPreferences.self, from: JSONEncoder().encode(bounded)) == bounded)
    }

    @Test func refinementKeepsBoundedLocalVisitsWithoutChangingPerVideoSamplePriority() {
        let plans: [[Double]] = [[60, 30, 90, 15, 45, 75], [12, 6, 18], []]
        let order = ThumbnailPolicy.refinementOrder(plans)
        #expect(order.map(\.video) == [0, 0, 0, 0, 1, 1, 1, 0, 0])
        for video in plans.indices {
            #expect(order.filter { $0.video == video }.map(\.position) == plans[video])
        }
        let fair = ThumbnailPolicy.refinementOrder([[1, 2, 3, 4, 5], [6, 7, 8, 9, 10]])
        #expect(fair.prefix(8).map(\.video) == [0, 0, 0, 0, 1, 1, 1, 1])
        #expect(ThumbnailPolicy.refinementOrder([]).isEmpty)
    }
}
