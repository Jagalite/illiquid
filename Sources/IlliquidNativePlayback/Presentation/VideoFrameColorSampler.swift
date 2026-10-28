import CoreVideo
import Foundation
import IlliquidCore

final class VideoFrameColorSampler: @unchecked Sendable {
    private static let sampleColumns = 12
    private static let sampleRows = 8
    private static let sceneCutRootMeanSquareThreshold = 0.28
    private static let publishRootMeanSquareThreshold = 0.012
    private static let publishMaximumComponentThreshold = 0.05
    private let minimumIntervalNanoseconds: UInt64
    private let smoothingTimeConstant: TimeInterval
    private var lastSampleUptimeNanoseconds: UInt64?
    private var lastRawSample: VideoColorSample?
    private var smoothedSample: VideoColorSample?
    private var lastPublishedSample: VideoColorSample?

    init(
        minimumInterval: TimeInterval = 0.25,
        smoothingTimeConstant: TimeInterval = 0.65
    ) {
        minimumIntervalNanoseconds = UInt64(
            max(0, minimumInterval) * 1_000_000_000
        )
        self.smoothingTimeConstant = max(0, smoothingTimeConstant)
    }

    func sampleIfNeeded(_ pixelBuffer: CVPixelBuffer) -> VideoColorSample? {
        sampleIfNeeded(
            pixelBuffer,
            uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
    }

    func sampleIfNeeded(
        _ pixelBuffer: CVPixelBuffer,
        uptimeNanoseconds now: UInt64
    ) -> VideoColorSample? {
        let elapsedNanoseconds = lastSampleUptimeNanoseconds.map {
            now >= $0 ? now - $0 : UInt64.max
        }
        if let lastSampleUptimeNanoseconds,
           now >= lastSampleUptimeNanoseconds,
           now - lastSampleUptimeNanoseconds < minimumIntervalNanoseconds
        {
            return nil
        }
        lastSampleUptimeNanoseconds = now
        guard let sample = Self.sample(pixelBuffer) else { return nil }
        let isSceneCut = lastRawSample.map {
            Self.rootMeanSquareDifference(between: $0, and: sample)
                >= Self.sceneCutRootMeanSquareThreshold
        } ?? false
        lastRawSample = sample

        let elapsed = elapsedNanoseconds.map { TimeInterval($0) / 1_000_000_000 }
            ?? 0
        let smoothed = if isSceneCut {
            sample
        } else if let previous = smoothedSample {
            Self.blend(
                previous: previous,
                current: sample,
                currentWeight: Self.smoothingWeight(
                    elapsed: elapsed,
                    timeConstant: smoothingTimeConstant
                )
            )
        } else {
            sample
        }
        smoothedSample = smoothed

        guard lastPublishedSample.map({
            Self.isMeaningfulChange(between: $0, and: smoothed)
        }) ?? true else {
            return nil
        }
        lastPublishedSample = smoothed
        return smoothed
    }

    func reset() {
        lastSampleUptimeNanoseconds = nil
        lastRawSample = nil
        smoothedSample = nil
        lastPublishedSample = nil
    }

    static func sample(_ pixelBuffer: CVPixelBuffer) -> VideoColorSample? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }

        let flags = CVPixelBufferLockFlags.readOnly
        guard CVPixelBufferLockBaseAddress(pixelBuffer, flags) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, flags) }

        guard let layout = PixelLayout(pixelBuffer) else { return nil }
        let matrix = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
        let matrixID: Int32? = matrix == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) ? 6
            : matrix == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String) ? 9 : nil
        let coefficients = PiPVideoMapping.colorCoefficients(matrix: matrixID)
        var colors: [SampledVideoColor] = []
        colors.reserveCapacity(sampleColumns * sampleRows)

        for row in 0..<sampleRows {
            let normalizedY = (Double(row) + 0.5) / Double(sampleRows)
            let y = min(height - 1, Int(normalizedY * Double(height)))

            for column in 0..<sampleColumns {
                let normalizedX = (Double(column) + 0.5) / Double(sampleColumns)
                let x = min(width - 1, Int(normalizedX * Double(width)))
                let color = color(
                    atX: x,
                    y: y,
                    layout: layout,
                    coefficients: coefficients
                )

                colors.append(color)
            }
        }

        return VideoColorSample(
            columns: sampleColumns,
            rows: sampleRows,
            colors: colors
        )
    }

    /// Addresses and strides are valid only during sample's read lock. Resolve
    /// them once per call; a reused pixel buffer may have different attachments
    /// or storage on a later call.
    private enum PixelLayout {
        case bgra(base: UnsafeRawPointer, bytesPerRow: Int)
        case biPlanar8(
            luma: UnsafeRawPointer, lumaBytesPerRow: Int,
            chroma: UnsafeRawPointer, chromaBytesPerRow: Int,
            isFullRange: Bool
        )
        case biPlanar10(
            luma: UnsafeRawPointer, lumaBytesPerRow: Int,
            chroma: UnsafeRawPointer, chromaBytesPerRow: Int,
            isFullRange: Bool
        )

        init?(_ pixelBuffer: CVPixelBuffer) {
            let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
            switch pixelFormat {
            case kCVPixelFormatType_32BGRA:
                guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                    return nil
                }
                self = .bgra(
                    base: UnsafeRawPointer(base),
                    bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer)
                )
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                 kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                 kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                 kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
                guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
                      let luma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
                      let chroma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
                else { return nil }
                let lumaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
                let chromaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
                if pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                    || pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                {
                    self = .biPlanar8(
                        luma: UnsafeRawPointer(luma), lumaBytesPerRow: lumaBytesPerRow,
                        chroma: UnsafeRawPointer(chroma), chromaBytesPerRow: chromaBytesPerRow,
                        isFullRange: pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                    )
                } else {
                    self = .biPlanar10(
                        luma: UnsafeRawPointer(luma), lumaBytesPerRow: lumaBytesPerRow,
                        chroma: UnsafeRawPointer(chroma), chromaBytesPerRow: chromaBytesPerRow,
                        isFullRange: pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                    )
                }
            default:
                return nil
            }
        }
    }

    private static func color(
        atX x: Int,
        y: Int,
        layout: PixelLayout,
        coefficients: SIMD4<Float>
    ) -> SampledVideoColor {
        switch layout {
        case let .bgra(base, bytesPerRow):
            bgraColor(atX: x, y: y, baseAddress: base, bytesPerRow: bytesPerRow)
        case let .biPlanar8(luma, lumaBytesPerRow, chroma, chromaBytesPerRow, isFullRange):
            biPlanar8Color(
                atX: x,
                y: y,
                lumaBase: luma,
                lumaBytesPerRow: lumaBytesPerRow,
                chromaBase: chroma,
                chromaBytesPerRow: chromaBytesPerRow,
                isFullRange: isFullRange,
                coefficients: coefficients
            )
        case let .biPlanar10(luma, lumaBytesPerRow, chroma, chromaBytesPerRow, isFullRange):
            biPlanar10Color(
                atX: x,
                y: y,
                lumaBase: luma,
                lumaBytesPerRow: lumaBytesPerRow,
                chromaBase: chroma,
                chromaBytesPerRow: chromaBytesPerRow,
                isFullRange: isFullRange,
                coefficients: coefficients
            )
        }
    }

    private static func bgraColor(
        atX x: Int,
        y: Int,
        baseAddress: UnsafeRawPointer,
        bytesPerRow: Int
    ) -> SampledVideoColor {
        let pixel = baseAddress
            .advanced(by: y * bytesPerRow + x * 4)
            .assumingMemoryBound(to: UInt8.self)
        return SampledVideoColor(
            red: Double(pixel[2]) / 255,
            green: Double(pixel[1]) / 255,
            blue: Double(pixel[0]) / 255
        )
    }

    private static func biPlanar8Color(
        atX x: Int,
        y: Int,
        lumaBase: UnsafeRawPointer,
        lumaBytesPerRow: Int,
        chromaBase: UnsafeRawPointer,
        chromaBytesPerRow: Int,
        isFullRange: Bool,
        coefficients: SIMD4<Float>
    ) -> SampledVideoColor {
        let luma = lumaBase
            .advanced(by: y * lumaBytesPerRow + x)
            .assumingMemoryBound(to: UInt8.self)
            .pointee
        let chroma = chromaBase
            .advanced(by: (y / 2) * chromaBytesPerRow + (x / 2) * 2)
            .assumingMemoryBound(to: UInt8.self)
        return yCbCrColor(
            y: Double(luma),
            cb: Double(chroma[0]),
            cr: Double(chroma[1]),
            ranges: isFullRange
                ? (0, 255, 128, 255)
                : (16, 235, 128, 224),
            coefficients: coefficients
        )
    }

    private static func biPlanar10Color(
        atX x: Int,
        y: Int,
        lumaBase: UnsafeRawPointer,
        lumaBytesPerRow: Int,
        chromaBase: UnsafeRawPointer,
        chromaBytesPerRow: Int,
        isFullRange: Bool,
        coefficients: SIMD4<Float>
    ) -> SampledVideoColor {
        let luma = lumaBase
            .advanced(by: y * lumaBytesPerRow + x * 2)
            .assumingMemoryBound(to: UInt16.self)
            .pointee >> 6
        let chroma = chromaBase
            .advanced(by: (y / 2) * chromaBytesPerRow + (x / 2) * 4)
            .assumingMemoryBound(to: UInt16.self)
        let cb = chroma[0] >> 6
        let cr = chroma[1] >> 6
        return yCbCrColor(
            y: Double(luma),
            cb: Double(cb),
            cr: Double(cr),
            ranges: isFullRange
                ? (0, 1023, 512, 1023)
                : (64, 940, 512, 896),
            coefficients: coefficients
        )
    }

    private static func yCbCrColor(
        y: Double,
        cb: Double,
        cr: Double,
        ranges: (
            lumaMinimum: Double,
            lumaMaximum: Double,
            chromaCenter: Double,
            chromaRange: Double
        ),
        coefficients: SIMD4<Float>
    ) -> SampledVideoColor {
        let normalizedY = (y - ranges.lumaMinimum)
            / (ranges.lumaMaximum - ranges.lumaMinimum)
        let normalizedCb = (cb - ranges.chromaCenter) / ranges.chromaRange
        let normalizedCr = (cr - ranges.chromaCenter) / ranges.chromaRange
        return SampledVideoColor(
            red: normalizedY + Double(coefficients.x) * normalizedCr,
            green: normalizedY + Double(coefficients.y) * normalizedCb + Double(coefficients.z) * normalizedCr,
            blue: normalizedY + Double(coefficients.w) * normalizedCb
        )
    }

    private static func blend(
        previous: VideoColorSample,
        current: VideoColorSample,
        currentWeight: Double
    ) -> VideoColorSample {
        guard previous.columns == current.columns,
              previous.rows == current.rows
        else { return current }
        return VideoColorSample(
            columns: current.columns,
            rows: current.rows,
            colors: zip(previous.colors, current.colors).map {
                blend(
                    previous: $0,
                    current: $1,
                    currentWeight: currentWeight
                )
            }
        )
    }

    private static func blend(
        previous: SampledVideoColor,
        current: SampledVideoColor,
        currentWeight: Double
    ) -> SampledVideoColor {
        let previousWeight = 1 - currentWeight
        return SampledVideoColor(
            red: previous.red * previousWeight + current.red * currentWeight,
            green: previous.green * previousWeight + current.green * currentWeight,
            blue: previous.blue * previousWeight + current.blue * currentWeight
        )
    }

    static func smoothingWeight(
        elapsed: TimeInterval,
        timeConstant: TimeInterval
    ) -> Double {
        guard elapsed > 0 else { return 0 }
        guard timeConstant > 0 else { return 1 }
        return min(max(1 - exp(-elapsed / timeConstant), 0), 1)
    }

    static func isMeaningfulChange(
        between previous: VideoColorSample,
        and current: VideoColorSample
    ) -> Bool {
        guard previous.columns == current.columns,
              previous.rows == current.rows
        else { return true }
        return rootMeanSquareDifference(between: previous, and: current)
                >= publishRootMeanSquareThreshold
            || maximumComponentDifference(between: previous, and: current)
                >= publishMaximumComponentThreshold
    }

    private static func rootMeanSquareDifference(
        between previous: VideoColorSample,
        and current: VideoColorSample
    ) -> Double {
        guard previous.columns == current.columns,
              previous.rows == current.rows
        else { return 1 }
        var sumOfSquares = 0.0
        for (previous, current) in zip(previous.colors, current.colors) {
            sumOfSquares += pow(previous.red - current.red, 2)
            sumOfSquares += pow(previous.green - current.green, 2)
            sumOfSquares += pow(previous.blue - current.blue, 2)
        }
        return sqrt(sumOfSquares / Double(previous.colors.count * 3))
    }

    private static func maximumComponentDifference(
        between previous: VideoColorSample,
        and current: VideoColorSample
    ) -> Double {
        guard previous.columns == current.columns,
              previous.rows == current.rows
        else { return 1 }
        return zip(previous.colors, current.colors).reduce(0) { result, pair in
            max(
                result,
                max(
                    abs(pair.0.red - pair.1.red),
                    max(
                        abs(pair.0.green - pair.1.green),
                        abs(pair.0.blue - pair.1.blue)
                    )
                )
            )
        }
    }
}
