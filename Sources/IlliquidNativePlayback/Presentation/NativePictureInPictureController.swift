import AVFoundation
import AVKit
import AppKit
import CoreMedia
import Foundation
import IlliquidCore

enum NativePictureInPictureTransitionPhase: Equatable, Sendable {
    case stopped
    case starting
    case active
    case stopping
}

enum NativePictureInPictureTransitionAction: Equatable, Sendable {
    case start
    case stop
}

struct NativePictureInPictureTransitionModel: Equatable, Sendable {
    private(set) var phase: NativePictureInPictureTransitionPhase = .stopped
    private(set) var desiredActive = false

    var presentsAsActive: Bool {
        phase == .active || phase == .stopping
    }

    mutating func request(
        active: Bool,
        isPossible: Bool
    ) -> NativePictureInPictureTransitionAction? {
        desiredActive = active
        if active {
            return startIfPossible(isPossible)
        }

        switch phase {
        case .starting, .active:
            phase = .stopping
            return .stop
        case .stopped, .stopping:
            return nil
        }
    }

    mutating func requestControllerReplacement(
        isPossible: Bool
    ) -> NativePictureInPictureTransitionAction? {
        switch phase {
        case .starting, .active:
            phase = .stopping
            return .stop
        case .stopping:
            return nil
        case .stopped:
            return startIfPossible(isPossible)
        }
    }

    mutating func possibilityChanged(
        isPossible: Bool
    ) -> NativePictureInPictureTransitionAction? {
        startIfPossible(isPossible)
    }

    mutating func didStart() -> NativePictureInPictureTransitionAction? {
        guard phase == .starting else { return nil }
        if desiredActive {
            phase = .active
            return nil
        }
        phase = .stopping
        return .stop
    }

    mutating func failedToStart() {
        phase = .stopped
        desiredActive = false
    }

    mutating func didStop(
        isPossible: Bool
    ) -> NativePictureInPictureTransitionAction? {
        if phase != .stopping {
            desiredActive = false
        }
        phase = .stopped
        return startIfPossible(isPossible)
    }

    mutating func prepareForStopCompletion() {
        if phase != .stopping {
            desiredActive = false
            phase = .stopping
        }
    }

    mutating func stopDeadlineElapsed(
        isPossible: Bool
    ) -> NativePictureInPictureTransitionAction? {
        didStop(isPossible: isPossible)
    }

    mutating func startDeferredUntilPossible() {
        if phase == .starting {
            phase = .stopped
        }
    }

    mutating func reset() {
        phase = .stopped
        desiredActive = false
    }

    private mutating func startIfPossible(
        _ isPossible: Bool
    ) -> NativePictureInPictureTransitionAction? {
        guard desiredActive, isPossible, phase == .stopped else {
            return nil
        }
        phase = .starting
        return .start
    }
}

private final class NativePictureInPictureFrameObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var token: NSObjectProtocol?

    func replace(with token: NSObjectProtocol) {
        let previous = lock.withLock {
            let previous = self.token
            self.token = token
            return previous
        }
        if let previous {
            NotificationCenter.default.removeObserver(previous)
        }
    }

    func cancel() {
        let previous = lock.withLock {
            let previous = token
            token = nil
            return previous
        }
        if let previous {
            NotificationCenter.default.removeObserver(previous)
        }
    }

    deinit {
        cancel()
    }
}

private final class NativePictureInPictureRestoreCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((Bool) -> Void)?

    init(_ completion: @escaping (Bool) -> Void) {
        self.completion = completion
    }

    func complete(_ restored: Bool) {
        let completion = lock.withLock {
            let completion = self.completion
            self.completion = nil
            return completion
        }
        completion?(restored)
    }
}

private final class NativePictureInPicturePlaybackSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var duration: TimeInterval = 0
    private var isPaused = true

    func update(duration: TimeInterval? = nil, isPaused: Bool? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let nextDuration = duration ?? self.duration
        let nextPaused = isPaused ?? self.isPaused
        let changed = abs(self.duration - nextDuration) > 0.001
            || self.isPaused != nextPaused
        self.duration = nextDuration
        self.isPaused = nextPaused
        return changed
    }

    func timeRange() -> CMTimeRange {
        lock.lock()
        defer { lock.unlock() }
        guard duration > 0 else { return .invalid }
        return CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
    }

    func paused() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isPaused
    }
}

@MainActor
final class NativePictureInPictureController: NSObject {
    static var isSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    private let onSetPlaying: (Bool) -> Void
    private let onSkip: (TimeInterval) -> Void
    private let onRestoreUserInterface:
        (@escaping @Sendable (Bool) -> Void) -> Void
    private let onViewportSizeChanged: (CGSize?) -> Void
    private let onStateChanged: (PictureInPictureState) -> Void
    private let onSessionEnded: () -> Void
    private let onDiagnostic: (String) -> Void

    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var pendingRebindDisplayLayer: AVSampleBufferDisplayLayer?
    private let pictureInPictureFrameObservation =
        NativePictureInPictureFrameObservation()
    private weak var pictureInPictureContentView: NSView?
    private var pictureInPictureLookupGeneration = 0
    private var lastPublishedViewportSize: CGSize?
    private var transitions = NativePictureInPictureTransitionModel()
    private var boundDisplayLayer: AVSampleBufferDisplayLayer?
    private var stopWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var stopDeadlineTask: Task<Void, Never>?
    private var stopDeadlineGeneration = 0
    private var isShutDown = false
    private nonisolated let playbackSnapshot = NativePictureInPicturePlaybackSnapshot()
    private(set) var state: PictureInPictureState = .unavailable

    private static let stopCallbackDeadline: Duration = .seconds(2)

    init(
        displayLayer: AVSampleBufferDisplayLayer,
        onSetPlaying: @escaping (Bool) -> Void,
        onSkip: @escaping (TimeInterval) -> Void,
        onRestoreUserInterface: @escaping (
            @escaping @Sendable (Bool) -> Void
        ) -> Void,
        onViewportSizeChanged: @escaping (CGSize?) -> Void,
        onStateChanged: @escaping (PictureInPictureState) -> Void,
        onSessionEnded: @escaping () -> Void = {},
        onDiagnostic: @escaping (String) -> Void
    ) {
        self.onSetPlaying = onSetPlaying
        self.onSkip = onSkip
        self.onRestoreUserInterface = onRestoreUserInterface
        self.onViewportSizeChanged = onViewportSizeChanged
        self.onStateChanged = onStateChanged
        self.onSessionEnded = onSessionEnded
        self.onDiagnostic = onDiagnostic
        super.init()

        guard Self.isSupported else {
            onDiagnostic("[native-pip] Picture in Picture is not supported on this Mac.")
            return
        }

        installController(displayLayer: displayLayer)
    }

    deinit {
        stopDeadlineTask?.cancel()
        for waiter in stopWaiters.values {
            waiter.resume()
        }
    }

    func updatePlayback(duration: TimeInterval, isPaused: Bool) {
        let normalizedDuration = duration.isFinite && duration > 0 ? duration : 0
        let didChange = playbackSnapshot.update(
            duration: normalizedDuration,
            isPaused: isPaused
        )
        if didChange {
            controller?.invalidatePlaybackState()
        }
    }

    func rebind(displayLayer: AVSampleBufferDisplayLayer) {
        guard !isShutDown, Self.isSupported else { return }
        pendingRebindDisplayLayer = displayLayer
        switch transitions.phase {
        case .starting, .active, .stopping:
            let action = transitions.requestControllerReplacement(
                isPossible: controller?.isPictureInPicturePossible == true
            )
            perform(action)
            publishCurrentState()
            return
        case .stopped:
            pendingRebindDisplayLayer = nil
            stopObservingPictureInPictureWindow()
            installController(displayLayer: displayLayer)
            reconcileDesiredState()
        }
    }

    func publishCurrentState() {
        guard let controller else {
            publishState(isPossible: false, isActive: false)
            return
        }
        publishState(
            isPossible: controller.isPictureInPicturePossible,
            isActive: transitions.presentsAsActive
        )
    }

    func setActive(_ active: Bool) {
        guard !isShutDown, let controller else { return }
        let isPossible = controller.isPictureInPicturePossible
        let action = transitions.request(active: active, isPossible: isPossible)
        if active, !isPossible {
            onDiagnostic("[native-pip] Picture in Picture is not currently possible.")
        }
        perform(action)
        publishCurrentState()
    }

    func startWhenPossible() {
        guard !isShutDown else { return }
        let action = transitions.request(
            active: true,
            isPossible: controller?.isPictureInPicturePossible == true
        )
        perform(action)
        publishCurrentState()
    }

    func stopAndWaitIfActive() async {
        guard transitions.phase != .stopped else {
            _ = transitions.request(
                active: false,
                isPossible: controller?.isPictureInPicturePossible == true
            )
            publishCurrentState()
            return
        }
        let waiterID = UUID()
        await withCheckedContinuation { continuation in
            stopWaiters[waiterID] = continuation
            let action = transitions.request(
                active: false,
                isPossible: controller?.isPictureInPicturePossible == true
            )
            perform(action)
            if transitions.phase == .stopped {
                resumeStopWaiter(waiterID)
            } else {
                ensureStopDeadline()
            }
        }
    }

    func shutdown() {
        guard !isShutDown else {
            resumeStopWaiters()
            return
        }
        isShutDown = true
        cancelStopDeadline()
        possibleObservation?.invalidate()
        possibleObservation = nil
        pendingRebindDisplayLayer = nil
        transitions.reset()
        stopObservingPictureInPictureWindow()
        if controller?.isPictureInPictureActive == true {
            controller?.stopPictureInPicture()
        }
        controller?.delegate = nil
        controller?.contentSource = nil
        controller = nil
        boundDisplayLayer = nil
        publishState(isPossible: false, isActive: false)
        resumeStopWaiters()
    }

    private func installController(displayLayer: AVSampleBufferDisplayLayer) {
        possibleObservation?.invalidate()
        possibleObservation = nil

        let previousController = controller
        previousController?.delegate = nil
        previousController?.contentSource = nil

        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        self.controller = controller
        boundDisplayLayer = displayLayer
        controller.invalidatePlaybackState()
        possibleObservation = controller.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, !isShutDown else { return }
                reconcileDesiredState()
                publishCurrentState()
            }
        }
    }

    private func publishState(isPossible: Bool, isActive: Bool) {
        let updated = PictureInPictureState(
            isPossible: isPossible,
            isActive: isActive
        )
        guard updated != state else { return }
        state = updated
        onStateChanged(updated)
    }

    private func reconcileDesiredState() {
        let action = transitions.possibilityChanged(
            isPossible: controller?.isPictureInPicturePossible == true
        )
        perform(action)
    }

    private func perform(_ action: NativePictureInPictureTransitionAction?) {
        guard !isShutDown, let action else { return }
        switch action {
        case .start:
            guard let controller, controller.isPictureInPicturePossible else {
                transitions.startDeferredUntilPossible()
                publishCurrentState()
                return
            }
            stopObservingPictureInPictureWindow()
            controller.startPictureInPicture()
        case .stop:
            guard let controller else {
                completeStopAfterDeadline()
                return
            }
            controller.stopPictureInPicture()
            ensureStopDeadline()
        }
    }

    private func ensureStopDeadline() {
        guard transitions.phase == .stopping, stopDeadlineTask == nil else {
            return
        }
        stopDeadlineGeneration &+= 1
        let generation = stopDeadlineGeneration
        stopDeadlineTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.stopCallbackDeadline)
            } catch {
                return
            }
            guard let self,
                  generation == stopDeadlineGeneration,
                  transitions.phase == .stopping
            else {
                return
            }
            stopDeadlineTask = nil
            completeStopAfterDeadline()
        }
    }

    private func cancelStopDeadline() {
        stopDeadlineGeneration &+= 1
        stopDeadlineTask?.cancel()
        stopDeadlineTask = nil
    }

    private func completeStopAfterDeadline() {
        guard transitions.phase == .stopping else {
            resumeStopWaiters()
            return
        }
        onDiagnostic(
            "[native-pip] Stop callback deadline elapsed; tearing down the local PiP controller."
        )
        possibleObservation?.invalidate()
        possibleObservation = nil
        controller?.delegate = nil
        controller?.contentSource = nil
        controller = nil
        finishStoppedSession(usedDeadlineFallback: true)
    }

    private func finishStoppedSession(usedDeadlineFallback: Bool) {
        cancelStopDeadline()
        stopObservingPictureInPictureWindow()
        transitions.prepareForStopCompletion()
        onSessionEnded()

        let replacementLayer: AVSampleBufferDisplayLayer?
        if let pendingRebindDisplayLayer {
            replacementLayer = pendingRebindDisplayLayer
            self.pendingRebindDisplayLayer = nil
        } else if controller == nil {
            replacementLayer = boundDisplayLayer
        } else {
            replacementLayer = nil
        }
        if !isShutDown, let replacementLayer {
            installController(displayLayer: replacementLayer)
        }

        let isPossible = controller?.isPictureInPicturePossible == true
        let action: NativePictureInPictureTransitionAction?
        if usedDeadlineFallback {
            action = transitions.stopDeadlineElapsed(isPossible: isPossible)
        } else {
            action = transitions.didStop(isPossible: isPossible)
        }
        publishCurrentState()
        resumeStopWaiters()
        perform(action)
    }

    private func resumeStopWaiter(_ id: UUID) {
        guard let waiter = stopWaiters.removeValue(forKey: id) else { return }
        waiter.resume()
    }

    private static func activePictureInPictureContentView() -> NSView? {
        // AVKit does not expose the macOS PiP viewport. On macOS 26 its
        // sample-buffer path hosts the source layer at 1:1, so use the
        // framework-owned PiP panel's content bounds to size the source layer.
        NSApp.windows.first {
            String(describing: type(of: $0)).contains("PIPPanel")
        }?.contentView
    }

    private func observePictureInPictureViewport(attempt: Int = 0) {
        guard controller?.isPictureInPictureActive == true else { return }

        guard let contentView = Self.activePictureInPictureContentView() else {
            guard attempt < 5 else {
                onDiagnostic(
                    "[native-pip] Could not resolve the Picture in Picture viewport."
                )
                publishPictureInPictureViewport(nil)
                return
            }

            let generation = pictureInPictureLookupGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                guard let self,
                      generation == self.pictureInPictureLookupGeneration
                else {
                    return
                }
                self.observePictureInPictureViewport(attempt: attempt + 1)
            }
            return
        }

        if pictureInPictureContentView !== contentView {
            contentView.postsFrameChangedNotifications = true
            pictureInPictureContentView = contentView
            let observation = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: contentView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self,
                          let contentView = self.pictureInPictureContentView
                    else {
                        return
                    }
                    self.publishPictureInPictureViewport(contentView.bounds.size)
                }
            }
            pictureInPictureFrameObservation.replace(with: observation)
        }

        publishPictureInPictureViewport(contentView.bounds.size)
    }

    private func publishPictureInPictureViewport(_ size: CGSize?) {
        let normalizedSize: CGSize?
        if let size,
           size.width.isFinite,
           size.height.isFinite,
           size.width > 0,
           size.height > 0
        {
            normalizedSize = size
        } else {
            normalizedSize = nil
        }

        guard normalizedSize != lastPublishedViewportSize else { return }
        lastPublishedViewportSize = normalizedSize
        onViewportSizeChanged(normalizedSize)
    }

    private func stopObservingPictureInPictureWindow() {
        pictureInPictureLookupGeneration &+= 1
        pictureInPictureFrameObservation.cancel()
        pictureInPictureContentView = nil
        publishPictureInPictureViewport(nil)
    }

    private func resumeStopWaiters() {
        let waiters = Array(stopWaiters.values)
        stopWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

extension NativePictureInPictureController: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        _ = playbackSnapshot.update(isPaused: !playing)
        let controllerID = ObjectIdentifier(pictureInPictureController)
        Task { @MainActor [weak self] in
            guard let self,
                  self.controller.map(ObjectIdentifier.init) == controllerID
            else {
                return
            }
            onSetPlaying(playing)
            controller?.invalidatePlaybackState()
        }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        playbackSnapshot.timeRange()
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        playbackSnapshot.paused()
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        let controllerID = ObjectIdentifier(pictureInPictureController)
        Task { @MainActor [weak self] in
            guard let self,
                  controller.map(ObjectIdentifier.init) == controllerID
            else {
                return
            }
            onDiagnostic(
                "[native-pip] Render size changed to \(newRenderSize.width)x\(newRenderSize.height)."
            )
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        let seconds = skipInterval.seconds
        if seconds.isFinite, seconds != 0 {
            let controllerID = ObjectIdentifier(pictureInPictureController)
            Task { @MainActor [weak self] in
                guard let self,
                      controller.map(ObjectIdentifier.init) == controllerID
                else {
                    return
                }
                onSkip(seconds)
            }
        }
        completionHandler()
    }

    nonisolated func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }
}

extension NativePictureInPictureController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        let controllerID = ObjectIdentifier(pictureInPictureController)
        Task { @MainActor [weak self] in
            guard let self,
                  controller.map(ObjectIdentifier.init) == controllerID
            else {
                return
            }
            let action = transitions.didStart()
            if transitions.phase == .active {
                observePictureInPictureViewport()
            }
            publishCurrentState()
            onDiagnostic("[native-pip] Picture in Picture started.")
            perform(action)
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        let message = error.localizedDescription
        let controllerID = ObjectIdentifier(pictureInPictureController)
        Task { @MainActor [weak self] in
            guard let self,
                  controller.map(ObjectIdentifier.init) == controllerID
            else {
                return
            }
            guard transitions.phase != .stopped else { return }
            cancelStopDeadline()
            transitions.failedToStart()
            stopObservingPictureInPictureWindow()
            publishCurrentState()
            onDiagnostic("[native-pip] Failed to start: \(message)")
            onSessionEnded()
            if let pendingRebindDisplayLayer {
                self.pendingRebindDisplayLayer = nil
                installController(displayLayer: pendingRebindDisplayLayer)
            }
            reconcileDesiredState()
            resumeStopWaiters()
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        let controllerID = ObjectIdentifier(pictureInPictureController)
        Task { @MainActor [weak self] in
            guard let self,
                  controller.map(ObjectIdentifier.init) == controllerID
            else {
                return
            }
            guard transitions.phase != .stopped else { return }
            onDiagnostic("[native-pip] Picture in Picture stopped.")
            finishStoppedSession(usedDeadlineFallback: false)
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        let controllerID = ObjectIdentifier(pictureInPictureController)
        let completion = NativePictureInPictureRestoreCompletion(completionHandler)
        Task { @MainActor [weak self] in
            guard let self,
                  controller.map(ObjectIdentifier.init) == controllerID
            else {
                completion.complete(false)
                return
            }
            onRestoreUserInterface { restored in
                completion.complete(restored)
            }
        }
    }
}
