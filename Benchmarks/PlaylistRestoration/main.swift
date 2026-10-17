import Foundation

guard CommandLine.arguments.count == 5,
      let count = Int(CommandLine.arguments[2]), count > 0,
      let rounds = Int(CommandLine.arguments[4]), rounds > 0,
      ["baseline", "candidate"].contains(CommandLine.arguments[1]),
      ["unchanged", "edited", "duplicates", "no-base"].contains(CommandLine.arguments[3]) else {
    FileHandle.standardError.write(Data("Usage: playlist-bench baseline|candidate COUNT SCENARIO ROUNDS\n".utf8))
    exit(2)
}
let variant = CommandLine.arguments[1]
let scenario = CommandLine.arguments[3]
let base = (0..<count).map { n in
    FolderPlaylistItem(url: URL(fileURLWithPath: "/Media/長いフォルダー/Café/Season \(n % 7)/Episode \(n).mkv"),
        dateAdded: Date(timeIntervalSince1970: Double(n)))
}
let ids = base.map(\.id)
var order = Array(base.reversed())
var saved = ids
switch scenario {
case "unchanged": break
case "edited":
    order = order.enumerated().filter { $0.offset % 4 != 0 }.map(\.element)
    order += (0..<count/4).map { FolderPlaylistItem(url: URL(fileURLWithPath: "/New/Episode \($0).mkv")) }
case "duplicates": order += order; saved += saved + ["/removed.mkv"]
case "no-base": saved = []
default: fatalError("unknown scenario")
}
@MainActor func run() -> [FolderPlaylistItem] {
    if variant == "baseline" { return BaselinePlaylistMutation.restoringOrder(order, ids: saved) }
    return PlaylistMutation.restoringOrder(order, ids: saved)
}
let expected = BaselinePlaylistMutation.restoringOrder(order, ids: saved)
precondition(run() == expected)
var milliseconds: [Double] = []
for _ in 0..<rounds {
    let start = DispatchTime.now().uptimeNanoseconds
    let result = run()
    let end = DispatchTime.now().uptimeNanoseconds
    milliseconds.append(Double(end - start) / 1_000_000)
    precondition(result == expected)
}
let result: [String: Any] = ["variant": variant, "count": count, "scenario": scenario,
    "rounds": rounds, "milliseconds": milliseconds, "verified_item_count": expected.count]
let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(decoding: json, as: UTF8.self))
