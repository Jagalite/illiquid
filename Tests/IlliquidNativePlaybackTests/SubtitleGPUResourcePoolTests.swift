import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Subtitle GPU resource pool", .serialized)
@MainActor
struct SubtitleGPUResourcePoolTests {
    private typealias Resource = MetalASSSubtitleRenderer.FrameResources
    private typealias Pool = MetalASSSubtitleRenderer.ResourcePool

    private final class WeakResource {
        weak var value: Resource?

        init(_ value: Resource) {
            self.value = value
        }
    }

    @Test func returnedResourcesAreReusedWithinTheSameSource() throws {
        let pool = Pool()
        var borrowed: Resource? = pool.acquire()
        weak var original = borrowed

        pool.release(try #require(borrowed))
        borrowed = nil
        #expect(original != nil)
        #expect(pool.snapshotForTesting().idleResourceCount == 1)

        let reused = pool.acquire()
        #expect(reused === original)
        #expect(pool.snapshotForTesting().idleResourceCount == 0)
        pool.release(reused)
        #expect(pool.snapshotForTesting().idleResourceCount == 1)
    }

    @Test func retirementReleasesEveryIdleResource() {
        let pool = Pool()
        let witnesses = populateIdleResources(in: pool, count: 8)

        #expect(witnesses.allSatisfy { $0.value != nil })
        #expect(pool.snapshotForTesting().idleResourceCount == witnesses.count)

        pool.retireSource()

        #expect(pool.snapshotForTesting().idleResourceCount == 0)
        #expect(witnesses.allSatisfy { $0.value == nil })

        // Repeated retirement of an empty pool must still allow later reuse.
        pool.retireSource()
        let next = pool.acquire()
        pool.release(next)
        #expect(pool.acquire() === next)
    }

    @Test func retirementPreservesBorrowedLifetimeButRejectsItsReturn() throws {
        let pool = Pool()
        var borrowed: Resource? = pool.acquire()
        weak var original = borrowed

        pool.retireSource()

        // A command-buffer completion owns this reference in production.
        // Retirement must leave that owner's resource alive and untouched.
        #expect(original != nil)
        #expect(pool.snapshotForTesting().idleResourceCount == 0)

        pool.release(try #require(borrowed))
        #expect(pool.snapshotForTesting().idleResourceCount == 0)
        #expect(original != nil)

        borrowed = nil
        #expect(original == nil)
    }

    @Test func delayedOldReturnCannotDisplaceCurrentSourceResources() throws {
        let pool = Pool()
        var old: Resource? = pool.acquire()
        weak var oldWitness = old

        pool.retireSource()
        let current = pool.acquire()
        pool.release(current)

        // Simulate an old completion arriving after the new source has
        // already returned a reusable resource.
        pool.release(try #require(old))
        old = nil

        #expect(oldWitness == nil)
        #expect(pool.snapshotForTesting().idleResourceCount == 1)
        #expect(pool.acquire() === current)
    }

    @Test func interleavedReturnsRemainRetiredAcrossMultipleSourceChanges() throws {
        let pool = Pool()
        var firstEarly: Resource? = pool.acquire()
        var firstLate: Resource? = pool.acquire()
        weak var firstEarlyWitness = firstEarly
        weak var firstLateWitness = firstLate

        pool.retireSource()
        var secondLate: Resource? = pool.acquire()
        weak var secondLateWitness = secondLate
        let secondIdleWitnesses = populateIdleResources(in: pool, count: 3)

        pool.release(try #require(firstEarly))
        firstEarly = nil
        #expect(firstEarlyWitness == nil)
        #expect(pool.snapshotForTesting().idleResourceCount == 3)

        pool.retireSource()
        #expect(secondIdleWitnesses.allSatisfy { $0.value == nil })
        #expect(firstLateWitness != nil)
        #expect(secondLateWitness != nil)

        let current = pool.acquire()
        pool.release(current)
        pool.release(try #require(secondLate))
        secondLate = nil
        pool.release(try #require(firstLate))
        firstLate = nil

        #expect(secondLateWitness == nil)
        #expect(firstLateWitness == nil)
        #expect(pool.snapshotForTesting().idleResourceCount == 1)
        #expect(pool.acquire() === current)
    }

    @Test func concurrentReturnsCannotRepopulateARetiredSource() {
        let pool = Pool()
        for _ in 0..<8 {
            let witnesses = raceReturnsAgainstRetirement(in: pool, count: 64)
            #expect(pool.snapshotForTesting().idleResourceCount == 0)
            #expect(witnesses.allSatisfy { $0.value == nil })
        }

        let current = pool.acquire()
        pool.release(current)
        #expect(pool.acquire() === current)
    }

    // The helper scopes ensure test-owned strong references have disappeared
    // before callers inspect weak lifetimes. All wrappers are checked out
    // together so this seeds distinct resources, rather than one reused slot.
    @inline(never)
    private func populateIdleResources(in pool: Pool, count: Int) -> [WeakResource] {
        let resources = (0..<count).map { _ in pool.acquire() }
        let witnesses = resources.map(WeakResource.init)
        for resource in resources {
            pool.release(resource)
        }
        return witnesses
    }

    @inline(never)
    private func raceReturnsAgainstRetirement(in pool: Pool, count: Int) -> [WeakResource] {
        let resources = (0..<count).map { _ in pool.acquire() }
        let witnesses = resources.map(WeakResource.init)
        // concurrentPerform joins every iteration before returning. No test
        // relies on a GPU callback, a sleep, or an assumed scheduling order.
        DispatchQueue.concurrentPerform(iterations: count + 1) { index in
            if index == count {
                pool.retireSource()
            } else {
                pool.release(resources[index])
            }
        }
        return witnesses
    }
}
