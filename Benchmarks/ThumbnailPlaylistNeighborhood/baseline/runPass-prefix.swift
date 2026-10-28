        let playlist = player.viewStore.playlist.map(\.url)
        let anchor = current.flatMap { playlist.firstIndex(of: $0) }
        let neighbors = anchor.map { index in
            Array(playlist[max(0, index - 4)..<min(playlist.count, index + 5)])
        } ?? []
        var urls = current.map { [$0] } ?? []
        urls += visible.sorted { $0.path < $1.path } + discovered + neighbors + recent.keys.sorted { $0.path < $1.path }
        var distances: [URL: Int] = [:]
        if let anchor {
            for index in max(0, anchor - 4)..<min(playlist.count, anchor + 5) {
                distances[playlist[index]] = abs(index - anchor)
            }
        }
        let candidates = urls.map { url in
            ThumbnailPolicy.Candidate(url: url, lastUsed: recent[url], isVisible: visible.contains(url),
                neighborDistance: distances[url])
        }
