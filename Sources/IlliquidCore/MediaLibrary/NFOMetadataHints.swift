import Foundation

/// A bounded subset of Kodi/Plex XML metadata used for local identification.
public enum NFOMetadataHints {
    public static func parse(_ data: Data) -> MediaMetadataHints? {
        guard data.count <= 128 * 1024, let text = String(data: data, encoding: .utf8),
              !text.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !text.localizedCaseInsensitiveContains("<!ENTITY") else { return nil }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        let delegate = MetadataDelegate()
        parser.delegate = delegate
        guard parser.parse(), delegate.valid, delegate.hasValue else { return nil }
        var result = delegate.hints
        result.sources = ["NFO"]
        return result
    }
}

private final class MetadataDelegate: NSObject, XMLParserDelegate {
    var hints = MediaMetadataHints()
    var valid = true
    var hasValue = false
    private var stack: [String] = []
    private var text = ""
    private var idProvider: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let name = elementName.lowercased()
        stack.append(name)
        guard stack.count <= 32 else { valid = false; parser.abortParsing(); return }
        text = ""
        if stack.count == 1 {
            switch name {
            case "movie": hints.content = .movie
            case "tvshow": hints.content = .show
            case "episodedetails": hints.content = .episode
            default: valid = false; parser.abortParsing()
            }
        }
        if stack.count == 2, name == "uniqueid" { idProvider = attributeDict["type"] }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard stack.count == 2 else { return }
        guard text.count + string.count <= 4096 else { valid = false; parser.abortParsing(); return }
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let value = String(data: CDATABlock, encoding: .utf8) { self.parser(parser, foundCharacters: value) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        defer { stack.removeLast(); text = "" }
        guard stack.count == 2 else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        switch elementName.lowercased() {
        case "title":
            if hints.content == .episode { hints.episodeTitle = value }
            else { hints.title = value }
            hasValue = true
        case "showtitle" where hints.content == .episode: hints.title = value; hasValue = true
        case "year" where hints.content != .episode:
            if let year = MediaMetadataHints.number(value), (1800...2099).contains(year) { hints.year = year; hasValue = true }
        case "season":
            if let season = MediaMetadataHints.number(value, maximum: 999) { hints.season = season; hasValue = true }
        case "episode":
            if let episode = MediaMetadataHints.number(value) { hints.episode = episode; hasValue = true }
        case "uniqueid":
            if let provider = idProvider, let id = MediaMetadataHints.catalogID(provider: provider, value: value) {
                // Episode IDs identify the episode, not the series used for grouping.
                if hints.content != .episode { hints.catalogIDs.append(id) }
                hasValue = true
            }
        default: break
        }
    }
}
