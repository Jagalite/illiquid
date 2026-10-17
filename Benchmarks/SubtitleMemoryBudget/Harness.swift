import Dispatch
import Foundation

// Compiled with an unmodified production budget source for each variant.
// This exercises CPU reservation bookkeeping; it does not allocate pixels,
// run libass, or measure native presentation.
@main
enum BudgetBenchmark {
    static func main() throws {
        let arguments = CommandLine.arguments
        precondition(arguments.count == 4, "usage: benchmark MODE LIVE_LEASES ITERATIONS")
        let mode = arguments[1]
        let count = Int(arguments[2])!
        let iterations = Int(arguments[3])!
        precondition(count >= 1 && iterations >= 1)

        let budget = SubtitleMemoryBudget()
        let stagingBytes = 1_024 * 1_024
        let target = budget.acquire(owner: .mainStaging, bytes: stagingBytes)!
        var background: [SubtitleMemoryBudget.Lease] = []
        // Four leases model the cardinality of a small text/PiP budget;
        // further entries model retained bitmap events. Bytes are only
        // reservations, not backing allocations or a playback fixture.
        let initialOwners: [SubtitleMemoryOwner] = [
            .mainLibass, .pictureInPictureLibass, .pictureInPictureStaging,
        ]
        for index in 0..<(count - 1) {
            let owner = index < initialOwners.count ? initialOwners[index] : .bitmapEvents
            background.append(budget.acquire(owner: owner, bytes: 4_096)!)
        }
        let initialSnapshot = budget.snapshot
        let requests: [(owner: SubtitleMemoryOwner, bytes: Int)] = [
            (.mainStaging, 4_096), (.pictureInPictureStaging, 4_096),
        ]

        func snapshotReceipt(_ snapshot: SubtitleMemoryBudgetSnapshot) -> UInt64 {
            var value = UInt64(snapshot.reservedBytes + snapshot.reservationsByOwner.count)
            for (owner, bytes) in snapshot.reservationsByOwner {
                let weight: UInt64
                switch owner {
                case .bitmapEvents: weight = 2
                case .mainLibass: weight = 3
                case .mainStaging: weight = 5
                case .pictureInPictureLibass: weight = 7
                case .pictureInPictureStaging: weight = 11
                }
                value &+= UInt64(bytes) * weight
            }
            return value
        }

        func run(_ operations: Int) -> UInt64 {
            var receipt: UInt64 = 0
            switch mode {
            case "resize-same":
                for _ in 0..<operations {
                    receipt &+= target.resize(to: stagingBytes) ? 1 : 0
                }
            case "resize-change":
                for index in 0..<operations {
                    receipt &+= target.resize(to: stagingBytes + (index & 1) * 4_096) ? 1 : 0
                }
            case "acquire-release":
                for _ in 0..<operations {
                    // The scoped lease must be destroyed before the next
                    // acquisition. Final snapshot parity also checks this.
                    if let lease = budget.acquire(owner: .bitmapEvents, bytes: 4_096) {
                        withExtendedLifetime(lease) { receipt &+= 1 }
                    }
                }
            case "preflight":
                for _ in 0..<operations {
                    receipt &+= budget.canAcquire(requests) ? 1 : 0
                }
            case "snapshot":
                for _ in 0..<operations {
                    receipt &+= snapshotReceipt(budget.snapshot)
                }
            default:
                fatalError("unknown mode: \(mode)")
            }
            return receipt
        }

        // Equal warmup and timed operation counts across variants. The
        // functions contain locking and their results escape as JSON receipts.
        let warmupReceipt = run(2_000)
        precondition(target.resize(to: stagingBytes))
        let start = DispatchTime.now().uptimeNanoseconds
        let receipt = run(iterations)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        precondition(target.resize(to: stagingBytes))
        let finalSnapshot = budget.snapshot
        precondition(finalSnapshot == initialSnapshot, "reservation accounting changed")
        let expectedUnit = mode == "snapshot"
            ? snapshotReceipt(initialSnapshot)
            : 1
        precondition(receipt == UInt64(iterations) * expectedUnit, "operation result mismatch")
        precondition(warmupReceipt == 2_000 * expectedUnit, "warmup result mismatch")

        let result: [String: Any] = [
            "mode": mode,
            "live_leases": count,
            "iterations": iterations,
            "elapsed_ns": elapsed,
            "ns_per_operation": Double(elapsed) / Double(iterations),
            "receipt": receipt,
            "warmup_receipt": warmupReceipt,
            "reserved_bytes": finalSnapshot.reservedBytes,
            "owner_count": finalSnapshot.reservationsByOwner.count,
            "rejections": finalSnapshot.rejectedAcquisitions,
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        withExtendedLifetime((target, background, budget)) {}
    }
}
