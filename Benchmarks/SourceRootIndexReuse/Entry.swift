import IlliquidApp

// Tests import the library without linking a benchmark entry point.
@main
struct RootIndexBenchmarkEntry {
    static func main() async {
        await SourceRootIndexProbe.main()
    }
}
