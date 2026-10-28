
extension MediaSession {
    func recoveryEOFResearchState() -> (
        generation: Int?, packetCount: Int, payloadBytes: Int
    ) {
        videoRecoveryPackets.recoveryEOFResearchState()
    }

    func takePreparedVideoForRecoveryEOFResearch() -> [VideoFrameQueueItem] {
        // The harness runs only prepareForCommit(), waits for its complete
        // fixture plus EOF, and has no competing queue consumer or seek.
        let count = videoFrames.count
        var items: [VideoFrameQueueItem] = []
        items.reserveCapacity(count)
        for _ in 0..<count {
            switch videoFrames.pop() {
            case .value(let item):
                items.append(item)
            case .closed:
                return items
            }
        }
        return items
    }
}
