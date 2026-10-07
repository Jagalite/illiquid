import Foundation
import IlliquidCore
import Testing
@testable import IlliquidApp

@Suite("Launch URL queue")
struct LaunchOpenQueueTests {
    @Test("Early Launch Services URLs are retained until the runtime is ready")
    func queuesEarlyURLs() {
        var queue = LaunchOpenQueue()
        let video = URL(fileURLWithPath: "/tmp/Movie.mkv")
        let subtitle = URL(fileURLWithPath: "/tmp/Movie.en.srt")

        #expect(queue.receive(urls: [video]).isEmpty)
        #expect(queue.receive(urls: [subtitle]).isEmpty)
        #expect(
            queue.markReady()
                == [LaunchOpenRequest(urls: [video], mode: .replace),
                    LaunchOpenRequest(urls: [subtitle], mode: .replace)]
        )
        #expect(queue.markReady().isEmpty)
    }

    @Test("Ready queues route multiple-file and folder requests immediately")
    func routesReadyRequestsImmediately() {
        var queue = LaunchOpenQueue()
        _ = queue.markReady()
        let folder = URL(fileURLWithPath: "/tmp/Movies", isDirectory: true)
        let videos = [
            URL(fileURLWithPath: "/tmp/One.mkv"),
            URL(fileURLWithPath: "/tmp/Two.mp4"),
        ]

        #expect(
            queue.receive(urls: videos)
                == [LaunchOpenRequest(urls: videos, mode: .replace)]
        )
        #expect(
            queue.receive(urls: [folder], mode: .append)
                == [LaunchOpenRequest(urls: [folder], mode: .append)]
        )
    }
}
