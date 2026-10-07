import AppKit
import Darwin
import Foundation
import IlliquidCore
import IlliquidPlayback
import AVFoundation
import IlliquidNativePlayback

/// Standalone profiling uses the same application run loop as the player surface.
@main
@MainActor
struct IlliquidRenderProfile {
    static func main() {
        NSApplication.shared.setActivationPolicy(.regular)
        Task {
            do {
                try await run()
                NSApp.terminate(nil)
            } catch {
                fputs("render profile failed: \(error)\n", stderr)
                exit(1)
            }
        }
        NSApp.run()
    }

    static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["ILLIQUID_RENDER_PROFILE_FIXTURE"],
              let output = env["ILLIQUID_RENDER_PROFILE_RESULT"] else { throw ProfileError(message: "Set ILLIQUID_RENDER_PROFILE_FIXTURE and ILLIQUID_RENDER_PROFILE_RESULT") }
        NSApplication.shared.setActivationPolicy(.regular)
        let policy: NativeSoftwareVideoOutputPolicy = env["ILLIQUID_RENDER_PROFILE_BGRA"] == "1"
            ? .bgra : .planarPreferred
        let seekOnly = env["ILLIQUID_RENDER_PROFILE_SEEK_ONLY"] == "1"
        let backend = try NativePlaybackRuntime(softwareVideoOutputPolicy: policy,
            softwareSeekAccelerationEnabled: env["ILLIQUID_RENDER_PROFILE_DISABLE_SOFTWARE_BURST"] != "1")
        if env["ILLIQUID_RENDER_PROFILE_SOFTWARE"] == "1" {
            backend.setHardwareDecodingPolicy(.off)
        }
        let host = try backend.makeSurfaceHost()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Illiquid render qualification"
        window.contentView = host.view
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        host.view.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        backend.setMuted(true)
        var samples: [[String: Any]] = []
        var phases: [[String: Any]] = []
        let baselineRSS = ProcessResidentMemory.bytes() ?? 0
        let baselineHeap = ProcessHeapMemory.bytesInUse()
        func footprint() -> UInt64? {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return status == KERN_SUCCESS ? info.phys_footprint : nil
        }
        let baselineFootprint = footprint()
        let start = ProcessInfo.processInfo.systemUptime

        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        func capture(_ phase: String, lateness: Double) {
            guard let s = backend.diagnosticSnapshot else { return }
            samples.append([
                "phase": phase, "elapsed_s": ProcessInfo.processInfo.systemUptime - start,
                "rss_bytes": ProcessResidentMemory.bytes() ?? 0,
                "footprint_bytes": footprint() as Any? ?? NSNull(),
                "heap_bytes": ProcessHeapMemory.bytesInUse(), "heartbeat_late_ms": lateness * 1_000,
                "renderer_time_s": s.rendererMediaTimeSeconds, "renderer_rate": s.rendererRate,
                "submitted": s.framesSubmitted, "starvations": s.rendererStarvations,
                "video_frame_queue_peak": s.peakVideoFrameQueueDepth,
                "pipeline_capacity": s.videoPipelineCapacity,
                "pool_buffers": s.softwarePoolAllocatedBuffers, "pool_timeouts": s.softwarePoolTimeouts,
                "bgra_fallback_frames": s.softwareBGRAFallbackFrames,
                "ffmpeg_pixel_format": s.ffmpegPixelFormat,
                "pixel_format": s.pixelBufferFormat,
                "renderer_failure": s.rendererFailure as Any? ?? NSNull(),
                "window_visible": window.isVisible,
                "window_occlusion_visible": window.occlusionState.contains(.visible),
            ])
        }
        func phase(_ name: String, seconds: Double) async throws {
            let wall = ProcessInfo.processInfo.systemUptime
            let cpu = cpuSeconds()
            let initialTime = backend.diagnosticSnapshot?.rendererMediaTimeSeconds ?? 0
            while ProcessInfo.processInfo.systemUptime - wall < seconds {
                let before = ProcessInfo.processInfo.systemUptime
                try await Task.sleep(for: .milliseconds(100))
                capture(name, lateness: max(0, ProcessInfo.processInfo.systemUptime - before - 0.1))
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - wall
            phases.append(["phase": name, "wall_s": elapsed,
                "cpu_percent_one_core": (cpuSeconds() - cpu) / elapsed * 100,
                "renderer_advance_s": (backend.diagnosticSnapshot?.rendererMediaTimeSeconds ?? 0) - initialTime])
        }
        func waitFor(samplingPhase: String? = nil, _ predicate: () -> Bool) async throws -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + 15
            while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(10))
                if let samplingPhase { capture(samplingPhase, lateness: 0) }
            }
            return predicate()
        }
        do {
            let source = MediaSource.localFile(URL(fileURLWithPath: path))
            let request = try require(MediaLoadRequest(source: source, origin: .userSelected))
            try backend.load(.init(media: request, identity: PlayerSessionIdentity(source: source, generation: 1)))
            let ready = try await waitFor { backend.diagnosticSnapshot?.isPrerolled == true }
            try require(ready)
            if env["ILLIQUID_RENDER_PROFILE_OCCLUSION"] == "1" {
                try await investigateOcclusion(backend: backend, window: window, output: output, fixture: path)
                await backend.shutdown()
                return
            }
            let startupMS = (ProcessInfo.processInfo.systemUptime - start) * 1_000
            var readbackAvailable = false
            if seekOnly {
                backend.pause()
                try await phase("before-seek", seconds: 1)
            } else {
                backend.play()
                try await phase("warmup", seconds: 2)
                try await phase("playing-visible", seconds: 8)
                backend.setVideoColorSamplingEnabled(true)
                try await phase("playing-color-sampling", seconds: 4)
                backend.setVideoColorSamplingEnabled(false)
                backend.pause()
                try await phase("pause-settle", seconds: 1)
                try await phase("paused-visible", seconds: 4)
                readbackAvailable = videoLayer(in: host.view.layer)?.sampleBufferRenderer.displayedPixelBuffer() != nil
                window.orderOut(nil)
                try await phase("paused-hidden", seconds: 4)
                backend.play()
                try await phase("playing-hidden", seconds: 4)
            }
            backend.pause()
            window.orderFrontRegardless()
            let seekStart = ProcessInfo.processInfo.systemUptime
            let seekCPU = cpuSeconds()
            let previousFence = backend.diagnosticSnapshot?.presentationFence
            backend.seek(to: 8.5, mode: .absoluteExact)
            let sought = try await waitFor(samplingPhase: seekOnly ? "seeking" : nil) {
                backend.diagnosticSnapshot?.presentationFence != previousFence
                    && backend.diagnosticSnapshot?.isPrerolled == true
            }
            try require(sought)
            let seekMS = (ProcessInfo.processInfo.systemUptime - seekStart) * 1_000
            if seekOnly {
                phases.append(["phase": "seeking", "wall_s": seekMS / 1_000,
                    "cpu_time_ms": (cpuSeconds() - seekCPU) * 1_000,
                    "cpu_percent_one_core": (cpuSeconds() - seekCPU) / (seekMS / 1_000) * 100])
                backend.play()
                try await phase("seek-handoff", seconds: 4)
                try require(backend.diagnosticSnapshot?.ffmpegPixelFormat == "videotoolbox_vld")
                try await phase("hardware-resumed", seconds: 4)
                backend.pause()
                try await phase("paused-after-seek", seconds: 1)
            }
            let final = try require(backend.diagnosticSnapshot)
            try require(final.rendererFailure == nil)
            let shutdownStart = ProcessInfo.processInfo.systemUptime
            await backend.shutdown()
            let shutdownMS = (ProcessInfo.processInfo.systemUptime - shutdownStart) * 1_000
            try await Task.sleep(for: .seconds(1))
            let result: [String: Any] = [
                "fixture": path, "software_policy": policy.rawValue,
                "seek_only": seekOnly,
                "software_seek_acceleration": env["ILLIQUID_RENDER_PROFILE_DISABLE_SOFTWARE_BURST"] != "1",
                "forced_software": env["ILLIQUID_RENDER_PROFILE_SOFTWARE"] == "1",
                "paused_renderer_readback_available": readbackAvailable,
                "startup_to_preroll_ms": startupMS, "seek_to_preroll_ms": seekMS,
                "shutdown_ms": shutdownMS, "baseline_rss_bytes": baselineRSS,
                "baseline_footprint_bytes": baselineFootprint as Any? ?? NSNull(),
                "baseline_heap_bytes": baselineHeap,
                "after_shutdown_rss_bytes": ProcessResidentMemory.bytes() ?? 0,
                "after_shutdown_heap_bytes": ProcessHeapMemory.bytesInUse(),
                "after_shutdown_footprint_bytes": footprint() as Any? ?? NSNull(),
                "final_diagnostic": try JSONSerialization.jsonObject(with: JSONEncoder().encode(final)),
                "phases": phases, "samples": samples,
            ]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output), options: .atomic)
            print("render-profile result=\(output) startup-ms=\(startupMS) seek-ms=\(seekMS) shutdown-ms=\(shutdownMS)")
        } catch {
            await backend.shutdown()
            throw error
        }
    }

    static func investigateOcclusion(
        backend: NativePlaybackRuntime, window: NSWindow, output: String, fixture: String
    ) async throws {
        let cover = NSWindow(contentRect: window.frame.insetBy(dx: -20, dy: -20),
            styleMask: [.borderless], backing: .buffered, defer: false)
        cover.isReleasedWhenClosed = false
        cover.backgroundColor = .black
        cover.isOpaque = true
        cover.level = .floating
        defer { cover.orderOut(nil); cover.close() }
        backend.pause()
        var records: [[String: Any]] = []
        var checks: [Bool] = []
        func wait(_ predicate: () -> Bool) async throws -> Bool {
            let end = ContinuousClock.now + .seconds(3)
            while ContinuousClock.now < end {
                if predicate() { return true }
                try await Task.sleep(for: .milliseconds(10))
            }
            return predicate()
        }
        func current(_ target: Double) -> Bool {
            let state = backend.pausedReadbackDiagnostic()
            return state.isCurrent && state.displayedPTS.map { abs($0 - target) < 0.001 } == true
        }
        func record(_ phase: String, target: Double, elapsed: Double, verified: Bool) throws {
            records.append([
                "phase": phase, "target": target, "elapsed_ms": elapsed * 1000,
                "verified": verified, "window_visible": window.isVisible,
                "window_unoccluded": window.occlusionState.contains(.visible),
                "application_active": NSApp.isActive,
                "readback": try JSONSerialization.jsonObject(with: JSONEncoder().encode(backend.pausedReadbackDiagnostic())),
            ])
        }
        for cycle in 0..<2 {
            for (mode, target) in [("visible", 1.5), ("hidden", 8.5), ("covered", 10.5), ("hidden", 18.5)] {
                cover.orderOut(nil)
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                let initiallyVisible = try await wait { window.occlusionState.contains(.visible) }
                checks.append(initiallyVisible)
                if mode == "hidden" { window.orderOut(nil) }
                if mode == "covered" { cover.orderFrontRegardless() }
                if mode != "visible" {
                    checks.append(try await wait { !window.occlusionState.contains(.visible) })
                    try await Task.sleep(for: .milliseconds(500))
                }
                let began = ProcessInfo.processInfo.systemUptime
                backend.seek(to: target, mode: .absoluteExact)
                let settled = try await wait { !backend.pausedReadbackDiagnostic().seekInProgress }
                checks.append(settled)
                if mode == "visible" {
                    checks.append(try await wait { current(target) })
                } else {
                    try await Task.sleep(for: .milliseconds(500))
                }
                try record("cycle-\(cycle)-\(mode)", target: target,
                    elapsed: ProcessInfo.processInfo.systemUptime - began, verified: current(target))
                if mode != "visible" {
                    cover.orderOut(nil)
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    let revealed = ProcessInfo.processInfo.systemUptime
                    let recovered = try await wait { window.occlusionState.contains(.visible) && current(target) }
                    checks.append(recovered)
                    try record("cycle-\(cycle)-revealed", target: target,
                        elapsed: ProcessInfo.processInfo.systemUptime - revealed, verified: recovered)
                }
            }
        }
        let passed = checks.allSatisfy { $0 }
        let result: [String: Any] = ["status": passed ? "passed" : "failed", "fixture": fixture,
            "endpoint": "Current-generation paused buffer and PTS, real NSApplication.run; physical output not measured",
            "records": records, "checks": checks]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output), options: .atomic)
        try require(passed)
    }
}

private struct ProfileError: Error { let message: String }

@discardableResult
private func require(_ condition: Bool) throws -> Bool {
    guard condition else { throw ProfileError(message: "Profile precondition failed") }
    return condition
}

private func require<T>(_ value: T?) throws -> T {
    guard let value else { throw ProfileError(message: "Missing profile value") }
    return value
}

@MainActor
private func videoLayer(in layer: CALayer?) -> AVSampleBufferDisplayLayer? {
    if let video = layer as? AVSampleBufferDisplayLayer { return video }
    for child in layer?.sublayers ?? [] {
        if let video = videoLayer(in: child) { return video }
    }
    return nil
}

private enum ProcessResidentMemory {
    static func bytes() -> UInt64? {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? UInt64(info.resident_size) : nil
    }
}

private enum ProcessHeapMemory {
    static func bytesInUse() -> UInt64 {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(malloc_default_zone(), &statistics)
        return UInt64(statistics.size_in_use)
    }
}
