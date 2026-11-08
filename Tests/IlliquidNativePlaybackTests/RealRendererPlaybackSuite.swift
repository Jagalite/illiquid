import Testing

/// Suites that drive the real renderer, VideoToolbox and the main actor with
/// fixture media. Swift Testing runs separate suites in parallel; these
/// compete for the main actor and hardware decoders, which can delay a
/// main-actor hop past a playback deadline. Nesting them here runs them one
/// at a time. The Metal ASS compositor suite is here too: it does seconds of
/// synchronous image comparison on the main actor, which stalls any
/// playback runtime running alongside it.
@Suite("Real renderer playback", .serialized)
enum RealRendererPlayback {}
