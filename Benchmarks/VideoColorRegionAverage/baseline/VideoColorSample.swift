import Foundation

public struct SampledVideoColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
    }

    public var relativeLuminance: Double {
        0.2126 * Self.linearized(red)
            + 0.7152 * Self.linearized(green)
            + 0.0722 * Self.linearized(blue)
    }

    public var saturation: Double {
        let maximum = max(red, green, blue)
        guard maximum > 0 else { return 0 }
        return (maximum - min(red, green, blue)) / maximum
    }

    public var hue: Double {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        guard delta > 0 else { return 0 }

        let sector: Double
        if maximum == red {
            sector = (green - blue) / delta
        } else if maximum == green {
            sector = 2 + (blue - red) / delta
        } else {
            sector = 4 + (red - green) / delta
        }
        let normalized = sector / 6
        return normalized >= 0 ? normalized : normalized + 1
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value.isFinite ? value : 0, 0), 1)
    }

    private static func linearized(_ component: Double) -> Double {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }
}

public struct VideoColorSample: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    public let colors: [SampledVideoColor]

    public init(
        columns: Int,
        rows: Int,
        colors: [SampledVideoColor]
    ) {
        precondition(columns > 0 && rows > 0)
        precondition(colors.count == columns * rows)
        self.columns = columns
        self.rows = rows
        self.colors = colors
    }

    public var overall: SampledVideoColor {
        average(
            minimumColumn: 0,
            maximumColumn: columns - 1,
            minimumRow: 0,
            maximumRow: rows - 1
        )
    }

    public var leading: SampledVideoColor {
        average(
            minimumColumn: 0,
            maximumColumn: max(0, Int((Double(columns) * 0.32).rounded(.up)) - 1),
            minimumRow: 0,
            maximumRow: rows - 1
        )
    }

    public var bottom: SampledVideoColor {
        average(
            minimumColumn: 0,
            maximumColumn: columns - 1,
            minimumRow: min(
                rows - 1,
                Int((Double(rows) * 0.72 - 0.5).rounded(.up))
            ),
            maximumRow: rows - 1
        )
    }

    public func color(column: Int, row: Int) -> SampledVideoColor {
        colors[clampedRow(row) * columns + clampedColumn(column)]
    }

    public func average(
        minimumColumn: Int,
        maximumColumn: Int,
        minimumRow: Int,
        maximumRow: Int
    ) -> SampledVideoColor {
        let minimumColumn = clampedColumn(minimumColumn)
        let maximumColumn = max(minimumColumn, clampedColumn(maximumColumn))
        let minimumRow = clampedRow(minimumRow)
        let maximumRow = max(minimumRow, clampedRow(maximumRow))
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var count = 0

        for row in minimumRow...maximumRow {
            for column in minimumColumn...maximumColumn {
                let color = color(column: column, row: row)
                red += color.red
                green += color.green
                blue += color.blue
                count += 1
            }
        }

        return SampledVideoColor(
            red: red / Double(count),
            green: green / Double(count),
            blue: blue / Double(count)
        )
    }

    private func clampedColumn(_ column: Int) -> Int {
        min(max(column, 0), columns - 1)
    }

    private func clampedRow(_ row: Int) -> Int {
        min(max(row, 0), rows - 1)
    }
}
