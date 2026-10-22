import Foundation

#if !os(Linux) && !FOUNDATION_BOUNDARY_PROOF
#error("The Foundation boundary adapter belongs only in Linux correctness or native proof binaries")
#endif

// Swift 6.2.4 corelibs Foundation strips trailing slashes, then calls a helper
// requiring UTF-16 length > 1. Empty/root are already handled by Foundation.
// Keep this predicate scalar-based: a supplementary scalar uses two UTF-16 units.
func benchmarkNeedsParentPathBoundary(_ path: NSString) -> Bool {
    let scalars = (path as String).unicodeScalars
    guard let first = scalars.first, first.value <= 0xFFFF, first.value != 0x2F else { return false }
    return scalars.dropFirst().allSatisfy { $0.value == 0x2F }
}

func benchmarkParentPath(_ path: NSString) -> String {
    if benchmarkNeedsParentPathBoundary(path) { return "" }
    return path.deletingLastPathComponent
}
