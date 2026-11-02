
// Benchmark-only fixture construction. The runner appends this extension to an
// exact copy of the complete production file; it is not shipped in the app.
extension SourceTreeDirectoryState {
    @inline(never)
    static func benchmarkSeeded(
        contents: [(String, [SourceTreeEntry])],
        errors: [(String, String)]
    ) -> SourceTreeDirectoryState {
        let state = SourceTreeDirectoryState { _ in
            SourceDirectoryListing(entries: [], errorMessage: nil)
        }
        // Fresh tables, not copies of a retained seed dictionary. Input arrays
        // retain values but do not retain either dictionary's backing storage.
        state.directoryContents = Dictionary(uniqueKeysWithValues: contents)
        state.directoryErrors = Dictionary(uniqueKeysWithValues: errors)
        return state
    }
}
