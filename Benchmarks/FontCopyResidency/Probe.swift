import Foundation
import Darwin
import FontCopyProbe

private let stages = [
    "after_source_initialization", "priming_block_live", "priming_block_freed",
    "before_copy", "after_copy", "after_destination_read_touch",
    "after_source_read_touch", "after_pressure_relief", "after_source_release",
    "after_full_validation", "after_destination_release", "after_final_pressure_relief"
]

private func allocation(_ info: FCRAllocationInfo) -> [String: Any] {
    ["address": "0x" + String(info.address, radix: 16),
     "page_offset": info.page_offset, "malloc_size": info.malloc_size,
     "zone_address": "0x" + String(info.zone_address, radix: 16),
     "zone_name": info.zone_name.map { String(cString: $0) } ?? "none"]
}

private func snapshot(_ value: FCRSnapshot) -> [String: Any] {
    ["wall_nanoseconds": value.wall_nanoseconds,
     "malloc_bytes_in_use": value.malloc_bytes_in_use,
     "malloc_blocks_in_use": value.malloc_blocks_in_use,
     "malloc_bytes_allocated": value.malloc_bytes_allocated,
     "resident_size": value.resident_size, "phys_footprint": value.phys_footprint,
     "internal": value.internal, "reusable": value.reusable, "compressed": value.compressed,
     "task_info_result": value.task_info_result, "task_info_count": value.task_info_count]
}

@inline(never)
private func warmup() {
    let pointer = fcr_allocate(64, 0)!
    fcr_fill_pattern(pointer, 64)
    let data = Data(bytes: pointer, count: 64)
    data.withUnsafeBytes { _ = fcr_read_touch($0.baseAddress!, $0.count) }
    _ = fcr_allocation_info(pointer)
    fcr_release(pointer)
    var trace = FCRTrace()
    fcr_capture(&trace, 0)
}

@inline(never)
private func primeData(source: UnsafeRawPointer, count: Int, trace: inout FCRTrace) -> FCRAllocationInfo {
    var primer = Data(bytes: source, count: count)
    let info = primer.withUnsafeMutableBytes { bytes in
        // The only Data reference is this mutable local; dirty every destination byte.
        fcr_dirty(bytes.baseAddress!, count)
        let info = fcr_allocation_info(bytes.baseAddress)
        fcr_capture(&trace, 1)
        return info
    }
    primer = Data() // Destroy the owned payload before this non-inlined helper returns.
    return info
}

@main
private enum FontCopyResidency {
    static func main() throws {
        // Positional arguments avoid command-line parser allocations during measurement.
        let args = CommandLine.arguments
        guard args.count == 6, let count = Int(args[1]), [2, 4, 16].contains(count / 1_048_576),
              count % 1_048_576 == 0, ["aligned", "offset-one"].contains(args[2]),
              ["clean", "primed"].contains(args[3]),
              ["data", "volatile-copy", "vm-copy"].contains(args[4]),
              ["no-copy", "copy"].contains(args[5]) else {
            fatalError("usage: probe BYTES aligned|offset-one clean|primed data|volatile-copy|vm-copy no-copy|copy")
        }
        let alignment = args[2], cache = args[3], cohort = args[4], action = args[5]
        precondition(cohort != "vm-copy" || alignment == "aligned")
        let pageSize = fcr_page_size()
        precondition(count % pageSize == 0)
        let offset = alignment == "aligned" ? 0 : 1
        let allocationBytes = count + pageSize // Identical request for both logical alignments.
        var trace = FCRTrace()
        var primedInfo = FCRAllocationInfo(), destinationInfo = FCRAllocationInfo()
        var destinationChecksum: UInt64 = 0, sourceChecksum: UInt64 = 0
        var reliefAfterTouch = 0, reliefAfterRelease = 0, firstMismatch = count
        var contentsValid = true
        warmup()
        let initialRelief = fcr_pressure_relief()
        guard let sourceAllocation = fcr_allocate(allocationBytes, 1) else { fatalError("source allocation failed") }
        let source = sourceAllocation.advanced(by: offset)
        // Initialize all requested source pages, then give logical payload bytes the known pattern.
        fcr_dirty(sourceAllocation, allocationBytes)
        fcr_fill_pattern(source, count)
        let sourceInfo = fcr_allocation_info(sourceAllocation)
        fcr_capture(&trace, 0)

        if cache == "primed", cohort == "data" {
            primedInfo = primeData(source: source, count: count, trace: &trace)
        } else {
            var primed: UnsafeMutableRawPointer?
            if cache == "primed" {
                primed = fcr_allocate(count, cohort == "vm-copy" ? 1 : 0)
                guard let primed else { fatalError("priming allocation failed") }
                fcr_dirty(primed, count)
                primedInfo = fcr_allocation_info(primed)
            }
            fcr_capture(&trace, 1)
            fcr_release(primed)
        }
        // Only numeric addresses and allocator-zone metadata survive; no freed bytes are read.
        fcr_capture(&trace, 2)
        fcr_capture(&trace, 3)

        var data: Data?
        var rawDestination: UnsafeMutableRawPointer?
        var vmCopyResult: Int32 = 0
        let begin = fcr_clock_nanoseconds()
        if action == "copy" {
            if cohort == "data" {
                data = Data(bytes: source, count: count)
            } else {
                rawDestination = fcr_allocate(count, cohort == "vm-copy" ? 1 : 0)
                guard let rawDestination else { fatalError("destination allocation failed") }
                if cohort == "volatile-copy" {
                    fcr_volatile_copy(source, rawDestination, count)
                } else {
                    precondition(UInt(bitPattern: rawDestination) % UInt(pageSize) == 0)
                    vmCopyResult = fcr_vm_copy(source, rawDestination, count)
                    precondition(vmCopyResult == 0, "vm_copy failed")
                }
            }
        }
        let elapsed = fcr_clock_nanoseconds() - begin

        func observe(_ destination: UnsafeRawPointer?) {
            // This first checkpoint precedes destination reads and allocator/zone introspection.
            fcr_capture(&trace, 4)
            destinationInfo = fcr_allocation_info(destination)
            if let destination { destinationChecksum = fcr_read_touch(destination, count) }
            fcr_capture(&trace, 5)
            sourceChecksum = fcr_read_touch(source, count)
            fcr_capture(&trace, 6)
            reliefAfterTouch = fcr_pressure_relief()
            fcr_capture(&trace, 7)
            fcr_release(sourceAllocation)
            fcr_capture(&trace, 8)
            if let destination {
                // Validate against the deterministic pattern, never against the freed source.
                contentsValid = fcr_validate_pattern(destination, count, &firstMismatch) == 1
            }
            fcr_capture(&trace, 9)
        }

        if let retainedData = data {
            // The borrow keeps Data's owned storage alive through source release and validation.
            retainedData.withUnsafeBytes { observe($0.baseAddress) }
        } else {
            observe(rawDestination.map { UnsafeRawPointer($0) })
        }
        data = nil
        fcr_release(rawDestination)
        rawDestination = nil
        fcr_capture(&trace, 10)
        reliefAfterRelease = fcr_pressure_relief()
        fcr_capture(&trace, 11)

        var samples: [String: Any] = [:]
        for (index, name) in stages.enumerated() {
            let value = fcr_sample(&trace, UInt32(index))
            precondition(value.task_info_result == 0, "TASK_VM_INFO failed")
            precondition(value.task_info_count >= fcr_required_task_info_count(), "TASK_VM_INFO fields unavailable")
            samples[name] = snapshot(value)
        }
        let hasDestination = action == "copy"
        let result: [String: Any] = [
            "schema_version": 1, "pid": ProcessInfo.processInfo.processIdentifier,
            "payload_bytes": count, "source_alignment": alignment, "cache": cache,
            "cohort": cohort, "action": action, "page_size": pageSize,
            "task_info_required_count": fcr_required_task_info_count(),
            "source_allocation_bytes": allocationBytes, "source_allocation": allocation(sourceInfo),
            "source_address": "0x" + String(sourceInfo.address + UInt64(offset), radix: 16),
            "source_page_offset": (sourceInfo.address + UInt64(offset)) % UInt64(pageSize),
            "priming_performed": cache == "primed", "priming_requested_bytes": cache == "primed" ? count : 0,
            "priming_api": cohort == "data" ? "Data(bytes:count:) plus unique mutable borrow" : (cohort == "vm-copy" ? "posix_memalign" : "malloc"),
            "priming_allocation": allocation(primedInfo), "destination_allocation": allocation(destinationInfo),
            "destination_reused_primed_address": hasDestination && cache == "primed" && destinationInfo.address == primedInfo.address,
            "copy_wall_nanoseconds": elapsed, "vm_copy_result": cohort == "vm-copy" && hasDestination ? vmCopyResult as Any : NSNull(),
            "destination_read_checksum": hasDestination ? destinationChecksum as Any : NSNull(),
            "source_read_checksum": sourceChecksum, "contents_valid_after_source_release": hasDestination ? contentsValid as Any : NSNull(),
            "validated_bytes": hasDestination ? firstMismatch : 0,
            "pressure_relief_reported_bytes": ["initial": initialRelief, "after_touch": reliefAfterTouch, "after_release": reliefAfterRelease],
            "stages": samples
        ]
        let encoded = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        FileHandle.standardOutput.write(encoded)
        FileHandle.standardOutput.write(Data([10]))
        if !contentsValid { exit(2) }
    }
}
