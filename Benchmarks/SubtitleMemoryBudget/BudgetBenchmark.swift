import Foundation

// Compile this unchanged harness with one complete production budget source.
// Each process times one operation and keeps its initial leases alive throughout.
@main
enum BudgetBenchmark {
    @inline(never)
    static func acquireAndRelease(_ budget: SubtitleMemoryBudget) -> Int {
        let lease = budget.acquire(owner: .bitmapEvents, bytes: 4_096)
        return lease == nil ? 0 : 1
    }

    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4,
              let count = Int(arguments[2]), count >= 1,
              let iterations = Int(arguments[3]), iterations > 0 else {
            fatalError("usage: budget-benchmark SCENARIO LIVE_LEASES ITERATIONS")
        }
        let scenario = arguments[1]
        let budget = SubtitleMemoryBudget()
        let textOwners: [SubtitleMemoryOwner] = [
            .mainStaging, .mainLibass, .pictureInPictureStaging,
            .pictureInPictureLibass, .pictureInPictureStaging,
            .mainLibass, .mainStaging, .pictureInPictureLibass,
            .pictureInPictureStaging,
        ]
        let leases = (0..<count).map { index in
            let owner = index < min(count, 9) ? textOwners[index] : .bitmapEvents
            return budget.acquire(owner: owner, bytes: 4_096)!
        }
        let primary = leases[0]
        let requests: [(owner: SubtitleMemoryOwner, bytes: Int)] = [
            (.mainLibass, 16_384), (.pictureInPictureLibass, 8_192),
        ]
        var checksum = 0
        var heldSnapshot = budget.snapshot
        let start = DispatchTime.now().uptimeNanoseconds
        switch scenario {
        case "resize-unchanged":
            for _ in 0..<iterations {
                checksum &+= primary.resize(to: 4_096) ? 1 : 0
            }
        case "resize-changing":
            for index in 0..<iterations {
                checksum &+= primary.resize(to: index.isMultiple(of: 2) ? 8_192 : 4_096) ? 1 : 0
            }
        case "resize-rejected":
            for _ in 0..<iterations {
                checksum &+= primary.resize(to: SubtitleMemoryBudget.productionLimitBytes + 1) ? 1 : 0
            }
        case "acquire-release":
            for _ in 0..<iterations { checksum &+= acquireAndRelease(budget) }
        case "preflight":
            for _ in 0..<iterations { checksum &+= budget.canAcquire(requests) ? 1 : 0 }
        case "snapshot":
            for _ in 0..<iterations {
                let snapshot = budget.snapshot
                checksum &+= snapshot.reservedBytes + snapshot.reservationsByOwner.count
            }
        case "held-snapshot-resize":
            for index in 0..<iterations {
                checksum &+= primary.resize(to: index.isMultiple(of: 2) ? 8_192 : 4_096) ? 1 : 0
                checksum &+= heldSnapshot.reservedBytes
                heldSnapshot = budget.snapshot
            }
        default:
            fatalError("unknown scenario: \(scenario)")
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let final = budget.snapshot
        let result: [String: Any] = [
            "scenario": scenario,
            "live_leases": count,
            "iterations": iterations,
            "elapsed_ns": elapsed,
            "ns_per_operation": Double(elapsed) / Double(iterations),
            "checksum": checksum,
            "reserved_bytes": final.reservedBytes,
            "by_owner": Dictionary(uniqueKeysWithValues: final.reservationsByOwner.map { ($0.key.rawValue, $0.value) }),
            "rejections": final.rejectedAcquisitions,
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        withExtendedLifetime((leases, heldSnapshot)) {}
    }
}
