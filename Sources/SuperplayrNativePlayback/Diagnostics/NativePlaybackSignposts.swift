import os.signpost

let nativeVideoSignpostLog = OSLog(
    subsystem: "com.superplayr.native-playback",
    category: "SoftwareVideo"
)

@inline(__always)
func withNativeVideoSignpost<Result>(
    _ name: StaticString,
    _ operation: () throws -> Result
) rethrows -> Result {
    let identifier = OSSignpostID(log: nativeVideoSignpostLog)
    os_signpost(
        .begin,
        log: nativeVideoSignpostLog,
        name: name,
        signpostID: identifier
    )
    defer {
        os_signpost(
            .end,
            log: nativeVideoSignpostLog,
            name: name,
            signpostID: identifier
        )
    }
    return try operation()
}
