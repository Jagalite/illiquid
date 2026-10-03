import Foundation

struct FontAttachment: Equatable, Sendable {
    let filename: String
    let mimeType: String?
    let data: Data

    var isSupportedFont: Bool {
        let extensionName = URL(fileURLWithPath: filename).pathExtension.lowercased()
        if ["ttf", "otf", "ttc"].contains(extensionName) { return true }
        guard let mimeType = mimeType?.lowercased() else { return false }
        return mimeType.contains("font")
            || mimeType == "application/x-truetype-font"
            || mimeType == "application/vnd.ms-opentype"
    }
}

struct FontAttachmentLimits: Equatable, Sendable {
    var maximumCount = 64
    var maximumBytesPerFont = 16 * 1_024 * 1_024
    var maximumTotalBytes = 64 * 1_024 * 1_024

    static let production = Self()
}

enum FontAttachmentValidator {
    static func validated(
        _ attachments: [FontAttachment],
        limits: FontAttachmentLimits = .production
    ) throws -> [FontAttachment] {
        let fonts = attachments.filter(\.isSupportedFont)
        guard fonts.count <= limits.maximumCount else {
            throw PresentationError("Media contains too many embedded fonts")
        }
        var totalBytes = 0
        for font in fonts {
            guard font.data.count <= limits.maximumBytesPerFont else {
                throw PresentationError("An embedded font exceeds the bounded byte limit")
            }
            let (nextTotal, overflow) = totalBytes.addingReportingOverflow(
                font.data.count
            )
            guard !overflow, nextTotal <= limits.maximumTotalBytes else {
                throw PresentationError("Embedded fonts exceed the bounded total byte limit")
            }
            totalBytes = nextTotal
        }
        return fonts
    }
}

final class FontAttachmentStore {
    private(set) var attachments: [FontAttachment] = []

    func replace(
        with attachments: [FontAttachment],
        limits: FontAttachmentLimits = .production
    ) throws {
        self.attachments = try FontAttachmentValidator.validated(
            attachments,
            limits: limits
        )
    }

    func removeAll() {
        attachments.removeAll()
    }
}
