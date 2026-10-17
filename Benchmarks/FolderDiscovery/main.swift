import Foundation
import Dispatch

struct DiscoveryReceipt: Encodable {
    let elapsedNanoseconds: UInt64
    let folderURL: URL
    let items: [FolderPlaylistItem]
}

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: folder-discovery-probe DIRECTORY")
}
let input = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let start = DispatchTime.now().uptimeNanoseconds
let playlist = try FolderPlaylistDiscovery.discover(in: input)
let elapsed = DispatchTime.now().uptimeNanoseconds - start
let receipt = DiscoveryReceipt(elapsedNanoseconds: elapsed, folderURL: playlist.folderURL, items: playlist.items)
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(receipt))
FileHandle.standardOutput.write(Data([10]))
