import Foundation
import Dispatch
import IlliquidCore
@testable import IlliquidApp

guard CommandLine.arguments.count == 4,
      let count = Int(CommandLine.arguments[1]), count > 0,
      let iterations = Int(CommandLine.arguments[3]), iterations > 0
else {
    fatalError("Usage: probe ITEM_COUNT nil|front|middle|last|absent ITERATIONS")
}
let position = CommandLine.arguments[2]
// Construction and URL normalization are outside the measured operation.
let items = (0..<count).map {
    FolderPlaylistItem(url: URL(fileURLWithPath: "/tmp/illiquid-neighborhood/item-\($0).mkv"))
}
let anchor: Int?
let current: URL?
switch position {
case "nil":
    anchor = nil
    current = nil
case "front":
    anchor = 0
    current = items[0].url
case "middle":
    anchor = count / 2
    current = items[count / 2].url
case "last":
    anchor = count - 1
    current = items[count - 1].url
case "absent":
    anchor = nil
    current = URL(fileURLWithPath: "/tmp/illiquid-neighborhood/absent.mkv")
default:
    fatalError("Unknown position: \(position)")
}

var expectedURLs: [URL] = []
var expectedDistances: [URL: Int] = [:]
if let anchor {
    for index in max(0, anchor - 4)..<min(count, anchor + 5) {
        expectedURLs.append(items[index].url)
        expectedDistances[items[index].url] = abs(index - anchor)
    }
}
func verify(
    _ value: ThumbnailPlaylistNeighborhood,
    expectedURLs: [URL],
    expectedDistances: [URL: Int]
) {
    precondition(value.urls == expectedURLs, "Neighborhood URL mismatch")
    precondition(value.distances == expectedDistances, "Distance mismatch")
    precondition(value.urls.count <= 9 && value.distances.count <= 9)
}
// Warmup and exact result validation are outside the timer.
verify(
    ThumbnailPlaylistNeighborhood(playlist: items, current: current),
    expectedURLs: expectedURLs, expectedDistances: expectedDistances
)
var checksum = 0
let start = DispatchTime.now().uptimeNanoseconds
for _ in 0..<iterations {
    let result = ThumbnailPlaylistNeighborhood(playlist: items, current: current)
    checksum &+= result.urls.count &+ result.distances.count
}
let elapsed = DispatchTime.now().uptimeNanoseconds - start
precondition(checksum == iterations * (expectedURLs.count + expectedDistances.count))
let result = ThumbnailPlaylistNeighborhood(playlist: items, current: current)
verify(result, expectedURLs: expectedURLs, expectedDistances: expectedDistances)
let distances = result.distances.map {
    ["url": $0.key.absoluteString, "distance": $0.value] as [String: Any]
}.sorted { ($0["url"] as! String) < ($1["url"] as! String) }
let receipt: [String: Any] = [
    "urls": result.urls.map(\.absoluteString),
    "distances": distances,
]
let report: [String: Any] = [
    "count": count,
    "position": position,
    "iterations": iterations,
    "elapsed_nanoseconds": elapsed,
    "checksum": checksum,
    "url_stride_bytes": MemoryLayout<URL>.stride,
    "receipt": receipt,
]
let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
