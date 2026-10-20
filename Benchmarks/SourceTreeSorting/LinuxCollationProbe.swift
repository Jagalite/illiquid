import Foundation

let prefix = "/media/Shows/A Very Long Series Name (2025)/Season 01/A Very Long Series Name (2025) - S01E1 - "
let suffix = " 1.mkv [1080p BluRay HEVC 10bit Multi-Audio DTS-HD MA 5.1].mkv"
let nfc = URL(fileURLWithPath: prefix + "caf\u{00E9}" + suffix)
let nfd = URL(fileURLWithPath: prefix + "cafe\u{0301}" + suffix)
var outcomes: [String: Int] = [:]
var violations = 0
for _ in 0..<10_000 {
    let left = nfc.lastPathComponent
    let right = nfd.lastPathComponent
    let forward = left.localizedStandardCompare(right).rawValue
    let reverse = right.localizedStandardCompare(left).rawValue
    outcomes["\(forward),\(reverse)", default: 0] += 1
    if forward != -reverse { violations += 1 }
}
let data = try! JSONSerialization.data(withJSONObject: [
    "locale": Locale.current.identifier,
    "canonically_equal": nfc.lastPathComponent == nfd.lastPathComponent,
    "nfc_utf8": Array(nfc.lastPathComponent.utf8),
    "nfd_utf8": Array(nfd.lastPathComponent.utf8),
    "comparison_outcomes": outcomes,
    "antisymmetry_violations": violations,
    "literal_path_forward": nfc.path.compare(nfd.path, options: [.literal]).rawValue,
    "literal_path_reverse": nfd.path.compare(nfc.path, options: [.literal]).rawValue,
], options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
