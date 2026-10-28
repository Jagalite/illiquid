
extension VideoRecoveryPacketBuffer {
    func recoveryEOFResearchState() -> (
        generation: Int?, packetCount: Int, payloadBytes: Int
    ) {
        lock.withLock {
            (generation: generation, packetCount: packets.count, payloadBytes: byteCount)
        }
    }
}
