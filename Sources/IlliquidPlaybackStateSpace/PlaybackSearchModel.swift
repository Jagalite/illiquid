public enum PlaybackSearchModel: String, CaseIterable, Codable, Hashable, Sendable {
  case seek
  case eofDrain = "eof-drain"
  case recovery
  case trackSubtitles = "track-subtitles"
  case stopShutdown = "stop-shutdown"
  case prerollBuffering = "preroll-buffering"
}
