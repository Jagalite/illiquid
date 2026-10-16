import Foundation
import XCTest
@testable import IlliquidNativePlayback

final class ThumbnailPromotionMailboxTests: XCTestCase {
    func testBoundedCoalescingKeepsAllAcceptedProtections() {
        let mailbox = ThumbnailPromotionMailbox(capacity: 2)
        XCTAssertEqual(mailbox.reserve("a", epoch: 0), .accepted(startDrain: true))
        XCTAssertEqual(mailbox.reserve("a", epoch: 0), .accepted(startDrain: false))
        XCTAssertEqual(mailbox.reserve("b", epoch: 0), .accepted(startDrain: false))
        XCTAssertEqual(mailbox.reserve("c", epoch: 0), .unavailable)
        XCTAssertEqual(mailbox.pendingCount, 2)
        XCTAssertTrue(mailbox.protects("a", epoch: 0))
        XCTAssertTrue(mailbox.protects("b", epoch: 0))
    }
    func testDequeuedRequestRemainsProtectedUntilAcknowledged() throws {
        let mailbox = ThumbnailPromotionMailbox()
        _ = mailbox.reserve("a", epoch: 0)
        let request = try XCTUnwrap(mailbox.next())
        XCTAssertFalse(mailbox.beginEviction("a", epoch: 0))
        XCTAssertEqual(mailbox.reserve("a", epoch: 0), .accepted(startDrain: false))
        mailbox.complete(request)
        XCTAssertTrue(mailbox.beginEviction("a", epoch: 0))
        XCTAssertEqual(mailbox.reserve("a", epoch: 0), .unavailable)
        mailbox.endEviction("a")
        XCTAssertNil(mailbox.next())
        XCTAssertEqual(mailbox.reserve("b", epoch: 0), .accepted(startDrain: true))
    }
    func testClearDoesNotLetStaleAcknowledgementRemoveNewProtection() throws {
        let mailbox = ThumbnailPromotionMailbox()
        _ = mailbox.reserve("a", epoch: 0)
        let old = try XCTUnwrap(mailbox.next())
        mailbox.reset(epoch: 1)
        XCTAssertEqual(mailbox.reserve("a", epoch: 0), .unavailable)
        XCTAssertEqual(mailbox.reserve("a", epoch: 1), .accepted(startDrain: false))
        mailbox.complete(old)
        XCTAssertTrue(mailbox.protects("a", epoch: 1))
        XCTAssertFalse(mailbox.protects("a", epoch: 0))
        mailbox.complete(try XCTUnwrap(mailbox.next()))
        XCTAssertNil(mailbox.next())
    }
    func testFlushWaitsForAcknowledgementAndResetUnblocksIt() async throws {
        let mailbox = ThumbnailPromotionMailbox()
        _ = mailbox.reserve("a", epoch: 0)
        let first = CompletionProbe()
        let waiting = Task.detached { await mailbox.waitUntilEmpty(); first.mark() }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(first.isComplete, "flush completed while protection was still pending")
        mailbox.complete(try XCTUnwrap(mailbox.next()))
        await waiting.value
        XCTAssertTrue(first.isComplete)
        XCTAssertNil(mailbox.next())
        _ = mailbox.reserve("b", epoch: 0)
        let second = CompletionProbe()
        let resetWaiter = Task.detached { await mailbox.waitUntilEmpty(); second.mark() }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(second.isComplete)
        mailbox.reset(epoch: 1)
        await resetWaiter.value
        XCTAssertTrue(second.isComplete)
    }
    func testReservationAndEvictionHaveOneLinearizationOrder() {
        for _ in 0..<5_000 {
            let mailbox = ThumbnailPromotionMailbox()
            let lock = NSLock()
            let result = ResultBits()
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                if index == 0 {
                    if case .accepted = mailbox.reserve("a", epoch: 0) {
                        lock.lock(); result.bits |= 1; lock.unlock()
                    }
                } else if mailbox.beginEviction("a", epoch: 0) {
                    lock.lock(); result.bits |= 2; lock.unlock()
                }
            }
            XCTAssertNotEqual(result.bits, 3, "reservation and background eviction both won")
            XCTAssertNotEqual(result.bits, 0, "neither operation won")
        }
    }
}
private final class ResultBits: @unchecked Sendable { var bits = 0 }

private final class CompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var complete = false
    func mark() { lock.lock(); complete = true; lock.unlock() }
    var isComplete: Bool { lock.lock(); defer { lock.unlock() }; return complete }
}
