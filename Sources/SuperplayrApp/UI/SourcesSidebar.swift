import AppKit
import Observation
import SwiftUI
import SuperplayrCore

enum SourcesSidebarPreferences {
    static let widthKey = "Superplayr.playlist-sidebar-width.v1"
    static let nameSortKey = "Superplayr.sources-sidebar-sort-name.v2"
    static let dateCreatedSortKey = "Superplayr.sources-sidebar-sort-date-created.v2"
    static let typeSortKey = "Superplayr.sources-sidebar-sort-type.v2"

    static let defaultWidth = Double(SourcesSidebarSizing.defaultWidth)
    static let defaultNameSort = SourceTreeSortDirection.ascending.rawValue
    static let defaultDateCreatedSort = SourceTreeSortDirection.off.rawValue
    static let defaultTypeSort = SourceTreeSortDirection.off.rawValue
}

struct SourcesSidebar: View {
    @Bindable var model: AppModel
    let maximumWidth: CGFloat

    @Binding var searchText: String
    @Binding var expandedFolderIDs: Set<String>
    @Binding var knownSourceFolderIDs: Set<String>
    @Binding var hasInitializedExpansion: Bool
    let layout: SourcesSidebarLayoutState

    @State private var directoryContents: [String: [SourceTreeEntry]] = [:]
    @State private var directoryErrors: [String: String] = [:]
    @State private var loadingFolderIDs: Set<String> = []
    @State private var directoryLoadTasks: [String: Task<Void, Never>] = [:]
    @State private var recursiveMediaEntries: [SourceTreeEntry] = []
    @State private var recursiveMediaLoadTask: Task<Void, Never>?
    @State private var recursiveMediaLoadKey: String?
    @State private var isRecursiveMediaLoading = false
    @State private var filesystemMonitor: SourceFilesystemMonitor?
    @State private var pendingFilesystemEvents: [SourceFilesystemEvent] = []
    @State private var filesystemDebounceTask: Task<Void, Never>?
    @State private var browserFilter = SourceBrowserFilter()
    @State private var filterTask: Task<Void, Never>?
    @State private var visibleRows: [SourceTreeDisplayRow] = []
    @State private var hiddenItemCount = 0
    @State private var regexMatchCounts: [String: Int] = [:]
    @State private var previewRegexRuleID: String?
    @State private var isVisibilityPresented = false
    @State private var resizeState = SourcesSidebarResizeState()
    @State private var isDropTargeted = false
    @Environment(\.playerTheme) private var theme
    @AppStorage(SourcesSidebarPreferences.widthKey)
    private var storedSidebarWidth = SourcesSidebarPreferences.defaultWidth
    @AppStorage(SourcesSidebarPreferences.nameSortKey)
    private var storedNameSortDirection = SourcesSidebarPreferences.defaultNameSort
    @AppStorage(SourcesSidebarPreferences.dateCreatedSortKey)
    private var storedDateSortDirection = SourcesSidebarPreferences.defaultDateCreatedSort
    @AppStorage(SourcesSidebarPreferences.typeSortKey)
    private var storedTypeSortDirection = SourcesSidebarPreferences.defaultTypeSort

    private var settledSidebarWidth: CGFloat {
        SourcesSidebarSizing.settledWidth(
            storedWidth: CGFloat(storedSidebarWidth),
            maximumWidth: maximumWidth
        )
    }

    private var sortConfiguration: SourceTreeSortConfiguration {
        SourceTreeSortConfiguration(
            name: SourceTreeSortDirection.resolve(storedNameSortDirection),
            dateCreated: SourceTreeSortDirection.resolve(storedDateSortDirection),
            type: SourceTreeSortDirection.resolve(storedTypeSortDirection)
        )
    }

    private var sidebarSurface: some View {
        SourcesSidebarLiveViewport(
            resizeState: resizeState,
            settledWidth: settledSidebarWidth,
            maximumWidth: maximumWidth
        ) {
            VStack(spacing: 0) {
                header
                    .dynamicPlayerTextStyle(appliesControlTint: true)

                Divider()
                    .overlay(theme.separatorColor)

                if model.activeSourceTab == nil {
                    noTabsState
                } else if model.activeSourceItems.isEmpty {
                    emptyTabState
                } else {
                    sourceTools
                        .dynamicPlayerTextStyle(appliesControlTint: true)

                    if visibleRows.isEmpty && isActiveTabLoading {
                        activeTabLoadingState
                    } else if visibleRows.isEmpty {
                        noSearchResults
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(visibleRows) { row in
                                    sourceRow(row)
                                        .dynamicPlayerTextStyle()
                                        .padding(.horizontal, 7)
                                }
                            }
                            .padding(.bottom, 10)
                            .background {
                                SourcesSidebarScrollerConfigurator()
                                    .frame(width: 0, height: 0)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .dynamicPlayerTextStyle(
            contrastRegion: .leading,
            publishesLeadingRegion: true
        )
        .playerOverlaySurface(cornerRadius: 18, role: .sidebar)
        .overlay(alignment: .trailing) {
            SourcesSidebarResizeHandle(
                model: model,
                storedSidebarWidth: $storedSidebarWidth,
                maximumWidth: maximumWidth,
                settledWidth: settledSidebarWidth,
                resizeState: resizeState,
                layout: layout
            )
        }
        .onHover { isHovering in
            model.setPointerRegion(isHovering ? .sidebar : .video)
            model.setChromePin(.pointerOverSidebar, active: isHovering)
        }
    }

    private var sidebarWithSourceUpdates: some View {
        sidebarSurface
        .onAppear {
            resizeState.setLiveWidth(settledSidebarWidth)
            layout.setSidebarWidth(settledSidebarWidth)
            restartFilesystemMonitor(watching: model.allSourceWatchRoots)
            synchronizeSourceFolders(previous: [], current: model.allSourceFolders)
        }
        .onChange(of: isVisibilityPresented) { _, presented in
            model.setChromePin(.sourceVisibilityPopover, active: presented)
            model.setTransientPresentation(presented, owner: "source-visibility")
        }
        .onChange(of: settledSidebarWidth) { _, width in
            resizeState.setLiveWidth(width)
            layout.setSidebarWidth(width)
        }
        .onChange(of: model.allSourceWatchRoots) { _, current in
            restartFilesystemMonitor(watching: current)
        }
        .onChange(of: model.allSourceFolders) { previous, current in
            synchronizeSourceFolders(previous: previous, current: current)
        }
        .onChange(of: model.activeSourceItems) {
            activateSelectedSourceTab()
        }
        .onChange(of: model.activeSourceTabID) {
            // Don't leave another tab's files actionable while its replacement
            // projection is being computed in the background.
            visibleRows = []
            searchText = ""
            previewRegexRuleID = nil
            activateSelectedSourceTab()
        }
        .onChange(of: model.activeSourceVisibility) { previous, current in
            synchronizeRecursiveMediaScan()
            refreshVisibleRows(
                rebuildProjection: previous.viewMode != current.viewMode
            )
        }
    }

    var body: some View {
        sidebarWithSourceUpdates
        .onChange(of: previewRegexRuleID) {
            refreshVisibleRows()
        }
        .onChange(of: searchText) {
            refreshVisibleRows()
        }
        .onChange(of: storedNameSortDirection) {
            refreshVisibleRows(rebuildProjection: true)
        }
        .onChange(of: storedDateSortDirection) {
            refreshVisibleRows(rebuildProjection: true)
        }
        .onChange(of: storedTypeSortDirection) {
            refreshVisibleRows(rebuildProjection: true)
        }
        .onDisappear(perform: tearDownSidebar)
        .environment(\.colorScheme, theme.preferredColorScheme)
        .dropDestination(for: URL.self) { urls, _ in
            model.addDroppedItemsToActiveSourceTab(urls)
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
    }

    private func tearDownSidebar() {
        model.setChromePin(.sourceVisibilityPopover, active: false)
        model.setTransientPresentation(false, owner: "source-visibility")
        filterTask?.cancel()
        filterTask = nil
        resizeState.clear()
        layout.clear()
        directoryLoadTasks.values.forEach { $0.cancel() }
        directoryLoadTasks.removeAll()
        recursiveMediaLoadTask?.cancel()
        recursiveMediaLoadTask = nil
        filesystemDebounceTask?.cancel()
        filesystemDebounceTask = nil
        pendingFilesystemEvents.removeAll()
        filesystemMonitor?.stop()
        filesystemMonitor = nil
        loadingFolderIDs.removeAll()
        model.setChromePin(.pointerOverSidebar, active: false)
        model.setChromePin(.sidebarResize, active: false)
        model.setPlaybackFocus(false, owner: "source-search")
        model.setChromePin(.sourceVisibilityPopover, active: false)
    }

    @ViewBuilder
    private func sourceRow(_ row: SourceTreeDisplayRow) -> some View {
        switch row.kind {
        case let .folder(isRoot):
            SourceFolderRow(
                url: row.url,
                depth: row.depth,
                isRoot: isRoot,
                isExpanded: expandedFolderIDs.contains(row.folderID),
                isLoading: loadingFolderIDs.contains(row.folderID),
                hasError: directoryErrors[row.folderID] != nil,
                visibility: row.visibility,
                onToggleVisibility: {
                    toggleVisibility(of: row)
                }
            ) {
                toggleFolder(row.url)
            }
            .contextMenu {
                if row.visibility?.isInherited != true {
                    Button(
                        row.visibility == nil ? "Hide Folder" : "Show Folder"
                    ) {
                        toggleVisibility(of: row)
                    }
                    Divider()
                }
                Button("Open in New Tab") {
                    model.openSourceFolderTab(row.url)
                }
                Divider()
                Button("Reveal in Finder") {
                    model.revealSourceInFinder(row.url)
                }
                Button("Refresh Folder") {
                    refreshFolder(row.url)
                }
                if isRoot {
                    Divider()
                    Button("Remove Folder", role: .destructive) {
                        model.removeSourceFolder(row.url)
                    }
                }
            }

        case let .media(dateAdded):
            SourceFileRow(
                model: model,
                url: row.url,
                dateAdded: dateAdded,
                title: row.displayName,
                contextLabel: row.contextLabel,
                depth: row.depth,
                isCurrent: isCurrentFile(row.url),
                visibility: row.visibility,
                isProgressRefreshActive:
                    isCurrentFile(row.url)
                    && model.state.phase == .playing
                    && model.isUIObservationActive,
                onToggleVisibility: {
                    toggleVisibility(of: row)
                }
            ) {
                if row.visibility == nil {
                    model.playSourceFile(row.url)
                }
            }
            .contextMenu {
                if row.visibility?.isInherited != true {
                    Button(
                        row.visibility == nil ? "Hide File" : "Always Show File"
                    ) {
                        toggleVisibility(of: row)
                    }
                    Divider()
                }
                if row.visibility == nil {
                    Button(isCurrentFile(row.url) ? "Resume" : "Play") {
                        model.playSourceFile(row.url)
                    }
                    Divider()
                }
                Button("Reveal in Finder") {
                    model.revealSourceInFinder(row.url)
                }
                if let sourceItem = model.activeSourceItems.first(where: {
                    $0.kind == .file
                        && NormalizedFileURL.representsSameFile($0.url, row.url)
                }) {
                    Divider()
                    Button("Remove from Tab", role: .destructive) {
                        model.removeSourceItem(sourceItem)
                    }
                }
            }

        case .mediaSection:
            Text(row.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 12)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)

        case let .message(message):
            SourceTreeMessageRow(
                message: message,
                depth: row.depth
            )
        }
    }

    private func toggleVisibility(of row: SourceTreeDisplayRow) {
        if row.visibility == nil {
            model.hideActiveSource(row.url)
        } else if row.visibility?.isManual == true,
                  row.visibility?.regexMatches.isEmpty == true
        {
            model.unhideActiveSource(row.url)
        } else {
            model.showActiveSource(row.url)
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                headerTitle
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 8)

                headerActions
            }

            HStack(spacing: 8) {
                Text(model.activeSourceTab?.displayName ?? "Sources")
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 4)

                headerActions
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Sources")
                .font(.headline.weight(.semibold))
                .lineLimit(1)
            Text(sourceCountLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var headerActions: some View {
        HStack(spacing: 2) {
            if !model.activeSourceItems.isEmpty {
                sortControls
            }

            Button(action: model.addSourceFilesPanel) {
                Image(systemName: "doc.badge.plus")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                    .playerIconHoverEffect(
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
            }
            .buttonStyle(.borderless)
            .help("Add Files to Tab…")
            .accessibilityLabel("Add Files to Tab")

            Button(action: model.addSourceFoldersPanel) {
                Image(systemName: "folder.badge.plus")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                    .playerIconHoverEffect(
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
            }
            .buttonStyle(.borderless)
            .help("Add Folder…")
            .accessibilityLabel("Add Folder")
        }
    }

    private var sourceTools: some View {
        HStack(spacing: 7) {
            SourcesSearchField(text: $searchText) { focused in
                model.setPlaybackFocus(focused, owner: "source-search")
            }
            .frame(height: 28)

            Button {
                isVisibilityPresented.toggle()
                model.setChromePin(
                    .sourceVisibilityPopover,
                    active: isVisibilityPresented
                )
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: visibilitySystemImage)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .playerIconHoverEffect(
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )

                    if activeVisibilityRuleCount > 0 {
                        Text("\(min(hiddenItemCount, 99))")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 3)
                            .frame(minWidth: 12, minHeight: 12)
                            .background(Color.accentColor, in: Capsule())
                            .offset(x: 3, y: -3)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(visibilityHelp)
            .accessibilityLabel("Source view and visibility")
            .accessibilityValue(visibilityHelp)
            .popover(isPresented: $isVisibilityPresented, arrowEdge: .top) {
                SourceVisibilityPopover(
                    model: model,
                    hiddenItemCount: hiddenItemCount,
                    regexMatchCounts: regexMatchCounts,
                    previewRegexRuleID: $previewRegexRuleID
                )
                .background(PopoverDismissalBoundary { isVisibilityPresented = false })
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var activeVisibilityRuleCount: Int {
        let visibility = model.activeSourceVisibility
        return visibility.manuallyHiddenPaths.count
            + visibility.regexRules.filter(\.isEnabled).count
    }

    private var visibilitySystemImage: String {
        let visibility = model.activeSourceVisibility
        if visibility.showsHiddenItems {
            return "eye"
        }
        return activeVisibilityRuleCount > 0
            ? "line.3.horizontal.decrease.circle.fill"
            : "line.3.horizontal.decrease.circle"
    }

    private var visibilityHelp: String {
        guard activeVisibilityRuleCount > 0 else {
            return "Choose source view and visibility"
        }
        return "\(hiddenItemCount) hidden source"
            + (hiddenItemCount == 1 ? "" : "s")
    }

    private var sortControls: some View {
        HStack(spacing: 3) {
            sortButton(
                criterion: .type,
                storedDirection: $storedTypeSortDirection
            )
            sortButton(
                criterion: .dateCreated,
                storedDirection: $storedDateSortDirection
            )
            sortButton(
                criterion: .name,
                storedDirection: $storedNameSortDirection
            )
        }
    }

    private func sortButton(
        criterion: SourceTreeSortCriterion,
        storedDirection: Binding<String>
    ) -> some View {
        let direction = SourceTreeSortDirection.resolve(
            storedDirection.wrappedValue
        )
        return Button {
            storedDirection.wrappedValue = direction.next.rawValue
        } label: {
            HStack(spacing: 3) {
                Image(systemName: criterion.systemImage)
                    .font(.system(size: 16, weight: .semibold))

                if let directionSystemImage = direction.systemImage {
                    Image(systemName: directionSystemImage)
                        .font(.system(size: 9, weight: .bold))
                } else {
                    Color.clear
                        .frame(width: 8, height: 9)
                }
            }
            .foregroundStyle(direction == .off ? .tertiary : .primary)
            .frame(width: 34, height: 30)
            .contentShape(Rectangle())
            .background(
                direction == .off ? Color.clear : Color.primary.opacity(0.11),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .help(
            "\(criterion.title): \(direction.title). "
                + "Click for \(direction.next.title.lowercased())."
        )
        .accessibilityLabel("Sort by \(criterion.title)")
        .accessibilityValue(direction.title)
    }

    private var noTabsState: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)

            VStack(spacing: 5) {
                Text("No Open Tabs")
                    .font(.headline)
                Text("Create a tab to collect files and folders.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button(action: model.createSourceTab) {
                Text("New Tab").playerProminentButtonTextStyle()
            }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var emptyTabState: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(isDropTargeted ? 0.10 : 0.045))
                    .frame(width: 72, height: 64)
                Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "plus")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(isDropTargeted ? .primary : .secondary)
            }

            VStack(spacing: 6) {
                Text(isDropTargeted ? "Drop to Add" : "This Tab Is Empty")
                    .font(.headline)
                Text("Add media files, folders, or drop them anywhere in this panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 230)
            }

            HStack(spacing: 8) {
                Button(action: model.addSourceFilesPanel) {
                    Label("Add Files", systemImage: "doc.badge.plus")
                }
                Button(action: model.addSourceFoldersPanel) {
                    Label("Add Folder", systemImage: "folder.badge.plus")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    Color.primary.opacity(isDropTargeted ? 0.26 : 0.10),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 5])
                )
                .padding(16)
        }
    }

    private var noSearchResults: some View {
        VStack(spacing: 8) {
            Image(systemName: emptyResultsSystemImage)
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(emptyResultsTitle)
                .font(.callout.weight(.medium))
            Text(emptyResultsMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            if searchText.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty, hiddenItemCount > 0
            {
                Button("Show Hidden Items") {
                    model.setActiveSourceShowsHiddenItems(true)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var emptyResultsSystemImage: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "magnifyingglass"
        }
        return hiddenItemCount > 0 ? "eye.slash" : "line.3.horizontal.decrease"
    }

    private var emptyResultsTitle: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No matching files or folders"
        }
        if hiddenItemCount > 0 {
            return hiddenItemCount == 1
                ? "1 source is hidden"
                : "\(hiddenItemCount) sources are hidden"
        }
        return "No sources in this view"
    }

    private var emptyResultsMessage: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Try a different search."
        }
        if hiddenItemCount > 0 {
            return "Show hidden items or adjust the visibility rules."
        }
        return "Choose another visibility view."
    }

    private var sourceCountLabel: String {
        guard let tab = model.activeSourceTab else { return "No tabs" }
        let count = tab.items.count
        let countLabel = count == 1 ? "1 source" : "\(count) sources"
        return "\(tab.displayName) · \(countLabel)"
    }

    private var isActiveTabLoading: Bool {
        isRecursiveMediaLoading || model.activeSourceFolders.contains { folder in
            loadingFolderIDs.contains(SourceTreeIdentity.folderID(for: folder))
        }
    }

    private var activeTabLoadingState: some View {
        VStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)
            Text("Loading sources…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func refreshVisibleRows(rebuildProjection _: Bool = false) {
        filterTask?.cancel()
        let input = SourceTreeProjectionInput(
            items: model.activeSourceItems, visibility: model.activeSourceVisibility,
            roots: model.activeSourceFolders, directoryContents: directoryContents,
            directoryErrors: directoryErrors, recursiveMediaEntries: recursiveMediaEntries,
            expandedFolderIDs: expandedFolderIDs, sortConfiguration: sortConfiguration
        )
        let revealsRulePreview = previewRegexRuleID != nil
        let query = searchText
        filterTask = Task {
            guard let projection = await browserFilter.project(
                input: input, revealsRulePreview: revealsRulePreview, query: query
            ), !Task.isCancelled else { return }
            if visibleRows != projection.rows { visibleRows = projection.rows }
            if hiddenItemCount != projection.hiddenCount { hiddenItemCount = projection.hiddenCount }
            if regexMatchCounts != projection.regexCounts { regexMatchCounts = projection.regexCounts }
        }
    }

    private func synchronizeSourceFolders(previous: [URL], current: [URL]) {
        let currentIDs = Set(current.map(SourceTreeIdentity.folderID))
        let removedFolders = previous.filter {
            !currentIDs.contains(SourceTreeIdentity.folderID(for: $0))
        }
        for folder in removedFolders {
            discardCachedTree(beneath: folder)
        }

        if !hasInitializedExpansion {
            expandedFolderIDs.formUnion(currentIDs)
            hasInitializedExpansion = true
        } else {
            expandedFolderIDs.formUnion(
                currentIDs.subtracting(knownSourceFolderIDs)
            )
        }
        knownSourceFolderIDs = currentIDs
        expandedFolderIDs = Set(expandedFolderIDs.filter { folderID in
            current.contains { root in
                SourceTreeIdentity.isFolderID(folderID, inside: root)
            }
        })

        persistExpansionState()
        activateSelectedSourceTab()
    }

    private func activateSelectedSourceTab() {
        for folder in model.activeSourceFolders {
            loadFolderIfNeeded(folder)
        }
        synchronizeRecursiveMediaScan()
        refreshVisibleRows(rebuildProjection: true)
    }

    private func synchronizeRecursiveMediaScan(force: Bool = false) {
        guard model.activeSourceVisibility.viewMode.scansRecursively else {
            recursiveMediaLoadTask?.cancel()
            recursiveMediaLoadTask = nil
            recursiveMediaLoadKey = nil
            recursiveMediaEntries = []
            isRecursiveMediaLoading = false
            return
        }

        let roots = model.activeSourceFolders
        let readsMetadata = model.activeSourceVisibility.viewMode == .media
        let files = readsMetadata ? model.activeSourceItems.filter { $0.kind == .file }.map(\.url) : []
        let key = [
            model.activeSourceTabID ?? "",
            readsMetadata ? "metadata" : "files",
            files.map(\.path).joined(separator: "\n"),
            roots.compactMap(SourceVisibilityPath.normalized).joined(separator: "\n"),
        ].joined(separator: "\u{0}")
        if force {
            recursiveMediaLoadKey = nil
        }
        guard recursiveMediaLoadKey != key else { return }

        recursiveMediaLoadTask?.cancel()
        recursiveMediaLoadKey = key
        recursiveMediaEntries = []
        isRecursiveMediaLoading = !roots.isEmpty || !files.isEmpty
        guard isRecursiveMediaLoading else {
            refreshVisibleRows(rebuildProjection: true)
            return
        }

        recursiveMediaLoadTask = Task { @MainActor in
            let result = await SourceRecursiveMediaLoader.load(roots, files: files, readsMetadata: readsMetadata)
            guard !Task.isCancelled, recursiveMediaLoadKey == key else { return }
            switch result {
            case let .success(entries): recursiveMediaEntries = entries
            case let .failure(error): model.player.reportError(error.localizedDescription)
            }
            recursiveMediaLoadTask = nil
            isRecursiveMediaLoading = false
            refreshVisibleRows(rebuildProjection: true)
        }
    }

    private func toggleFolder(_ folderURL: URL) {
        let folderID = SourceTreeIdentity.folderID(for: folderURL)
        if expandedFolderIDs.contains(folderID) {
            expandedFolderIDs.remove(folderID)
            cancelLoads(beneath: folderURL)
        } else {
            expandedFolderIDs.insert(folderID)
            loadFolderIfNeeded(folderURL)
        }
        persistExpansionState()
        refreshVisibleRows(rebuildProjection: true)
    }

    private func persistExpansionState() {
        SourcesSidebarExpansionStore.persist(
            SourcesSidebarExpansionSnapshot(
                expandedFolderIDs: expandedFolderIDs,
                knownSourceFolderIDs: knownSourceFolderIDs
            )
        )
    }

    private func refreshFolder(_ folderURL: URL) {
        let folderID = SourceTreeIdentity.folderID(for: folderURL)
        directoryLoadTasks[folderID]?.cancel()
        directoryLoadTasks[folderID] = nil
        directoryContents[folderID] = nil
        directoryErrors[folderID] = nil
        loadingFolderIDs.remove(folderID)
        refreshVisibleRows(rebuildProjection: true)
        if expandedFolderIDs.contains(folderID) {
            loadFolderIfNeeded(folderURL)
        }
    }

    private func restartFilesystemMonitor(watching roots: [URL]) {
        filesystemMonitor?.stop()
        filesystemMonitor = nil
        filesystemDebounceTask?.cancel()
        filesystemDebounceTask = nil
        pendingFilesystemEvents.removeAll()

        let monitor = SourceFilesystemMonitor { events in
            enqueueFilesystemEvents(events)
        }
        guard monitor.start(watching: roots) else { return }
        filesystemMonitor = monitor
    }

    private func enqueueFilesystemEvents(_ events: [SourceFilesystemEvent]) {
        pendingFilesystemEvents.append(contentsOf: events)
        filesystemDebounceTask?.cancel()
        filesystemDebounceTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let events = pendingFilesystemEvents
            pendingFilesystemEvents.removeAll()
            filesystemDebounceTask = nil
            applyFilesystemEvents(events)
        }
    }

    private func applyFilesystemEvents(_ events: [SourceFilesystemEvent]) {
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: events,
            roots: model.allSourceWatchRoots
        )
        guard !plan.isEmpty else { return }

        for path in plan.rootsToRescan {
            invalidateCachedTree(
                beneath: URL(fileURLWithPath: path, isDirectory: true),
                preserveExpansion: true
            )
        }
        for path in plan.treesToInvalidate {
            invalidateCachedTree(
                beneath: URL(fileURLWithPath: path, isDirectory: true),
                preserveExpansion: false
            )
        }
        if !plan.treesToInvalidate.isEmpty {
            persistExpansionState()
        }
        for path in plan.directoriesToReload {
            invalidateCachedDirectory(
                URL(fileURLWithPath: path, isDirectory: true)
            )
        }

        let activeRoots = model.activeSourceFolders
        if plan.affectsAny(model.activeSourceWatchRoots),
           model.activeSourceVisibility.viewMode.scansRecursively
        {
            synchronizeRecursiveMediaScan(force: true)
        }

        let activeRootPaths = Set(activeRoots.map {
            SourceTreeIdentity.folderID(for: $0)
        })
        let reloadPaths = plan.directoriesToReload.union(plan.rootsToRescan)
        for path in reloadPaths where isInsideActiveSource(path) {
            if activeRootPaths.contains(path) || expandedFolderIDs.contains(path) {
                loadFolderIfNeeded(URL(fileURLWithPath: path, isDirectory: true))
            }
        }
        refreshVisibleRows(rebuildProjection: true)
    }

    private func isInsideActiveSource(_ folderPath: String) -> Bool {
        model.activeSourceFolders.contains { root in
            SourceTreeIdentity.isFolderID(folderPath, inside: root)
        }
    }

    private func loadFolderIfNeeded(_ folderURL: URL) {
        let folderID = SourceTreeIdentity.folderID(for: folderURL)
        guard directoryContents[folderID] == nil,
              directoryErrors[folderID] == nil,
              directoryLoadTasks[folderID] == nil
        else {
            loadExpandedChildren(of: folderID)
            return
        }

        loadingFolderIDs.insert(folderID)
        let task = Task { @MainActor in
            let listing = await SourceDirectoryLoader.load(folderURL)
            guard !Task.isCancelled else { return }

            loadingFolderIDs.remove(folderID)
            directoryLoadTasks[folderID] = nil
            directoryContents[folderID] = listing.entries
            directoryErrors[folderID] = listing.errorMessage
            loadExpandedChildren(of: folderID)
            refreshVisibleRows(rebuildProjection: true)
        }
        directoryLoadTasks[folderID] = task
    }

    private func loadExpandedChildren(of folderID: String) {
        guard let entries = directoryContents[folderID] else { return }
        for entry in entries where entry.kind == .folder {
            let childID = SourceTreeIdentity.folderID(for: entry.url)
            if expandedFolderIDs.contains(childID) {
                loadFolderIfNeeded(entry.url)
            }
        }
    }

    private func cancelLoads(beneath folderURL: URL) {
        let folderPath = folderURL.absoluteURL.standardized.path
        let descendantIDs = directoryLoadTasks.keys.filter {
            let candidatePath = SourceTreeIdentity.path(fromFolderID: $0)
            return candidatePath == folderPath
                || candidatePath.hasPrefix(folderPath + "/")
        }
        for id in descendantIDs {
            directoryLoadTasks[id]?.cancel()
            directoryLoadTasks[id] = nil
            loadingFolderIDs.remove(id)
        }
    }

    private func discardCachedTree(beneath folderURL: URL) {
        invalidateCachedTree(beneath: folderURL, preserveExpansion: false)
    }

    private func invalidateCachedDirectory(_ folderURL: URL) {
        let folderID = SourceTreeIdentity.folderID(for: folderURL)
        directoryLoadTasks[folderID]?.cancel()
        directoryLoadTasks[folderID] = nil
        loadingFolderIDs.remove(folderID)
        directoryContents[folderID] = nil
        directoryErrors[folderID] = nil
    }

    private func invalidateCachedTree(
        beneath folderURL: URL,
        preserveExpansion: Bool
    ) {
        cancelLoads(beneath: folderURL)
        let folderPath = folderURL.absoluteURL.standardized.path
        let cachedIDs = Set(directoryContents.keys)
            .union(directoryErrors.keys)
            .filter {
                let candidatePath = SourceTreeIdentity.path(fromFolderID: $0)
                return candidatePath == folderPath
                    || candidatePath.hasPrefix(folderPath + "/")
            }
        if !preserveExpansion {
            expandedFolderIDs = Set(expandedFolderIDs.filter { id in
                let candidatePath = SourceTreeIdentity.path(fromFolderID: id)
                return candidatePath != folderPath
                    && !candidatePath.hasPrefix(folderPath + "/")
            })
        }
        for id in cachedIDs {
            directoryContents[id] = nil
            directoryErrors[id] = nil
        }
    }

    private func isCurrentFile(_ url: URL) -> Bool {
        guard let currentURL = model.state.currentURL else { return false }
        return NormalizedFileURL.representsSameFile(currentURL, url)
    }
}

@MainActor
@Observable
final class SourcesSidebarResizeState {
    private(set) var liveWidth: CGFloat?
    @ObservationIgnored private var isGestureActive = false

    func setLiveWidth(_ width: CGFloat) {
        if liveWidth != width {
            liveWidth = width
        }
    }

    func beginGesture() -> Bool {
        guard !isGestureActive else { return false }
        isGestureActive = true
        return true
    }

    func endGesture() {
        isGestureActive = false
    }

    /// GestureState also resets when SwiftUI cancels a drag without onEnded.
    func cancelGesture(restoring width: CGFloat) -> Bool {
        guard isGestureActive else { return false }
        isGestureActive = false
        setLiveWidth(width)
        return true
    }

    func clear() {
        liveWidth = nil
        isGestureActive = false
    }
}

private struct SourcesSidebarLiveViewport<Content: View>: View {
    @Bindable var resizeState: SourcesSidebarResizeState
    let settledWidth: CGFloat
    let maximumWidth: CGFloat
    let content: Content

    init(
        resizeState: SourcesSidebarResizeState,
        settledWidth: CGFloat,
        maximumWidth: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.resizeState = resizeState
        self.settledWidth = settledWidth
        self.maximumWidth = maximumWidth
        self.content = content()
    }

    var body: some View {
        content
            .frame(
                width: SourcesSidebarSizing.settledWidth(
                    storedWidth: resizeState.liveWidth ?? settledWidth,
                    maximumWidth: maximumWidth
                ),
                alignment: .leading
            )
            .clipped()
    }
}

private struct SourcesSidebarResizeHandle: View {
    @Environment(\.playerInterfaceScale) private var interfaceScale
    @Bindable var model: AppModel
    @Binding var storedSidebarWidth: Double
    let maximumWidth: CGFloat
    let settledWidth: CGFloat
    let resizeState: SourcesSidebarResizeState
    let layout: SourcesSidebarLayoutState

    @State private var isHovered = false
    @GestureState private var isResizing = false

    private var liveWidth: CGFloat {
        resizeState.liveWidth ?? settledWidth
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.clear)
                .frame(width: 12)

            Capsule()
                .fill(.primary.opacity(isHovered ? 0.34 : 0.14))
                .frame(width: 2, height: 42)
        }
        .contentShape(Rectangle())
        // Let the hosting view arbitrate hover with its other pointer regions.
        // A drag must never disable cursor rectangles for the entire window.
        .pointerStyle(.columnResize)
        .offset(x: 5)
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .updating($isResizing) { _, active, _ in active = true }
                .onChanged { value in
                    if resizeState.beginGesture() {
                        model.setChromePin(.sidebarResize, active: true)
                    }
                    updateLiveWidth(for: value.translation.width, interfaceScale: interfaceScale)
                }
                .onEnded { value in
                    let width = resolvedWidth(for: value.translation.width, interfaceScale: interfaceScale)
                    resizeState.setLiveWidth(width)
                    layout.setSidebarWidth(width)
                    storedSidebarWidth = Double(width)
                    resizeState.endGesture()
                    model.setChromePin(.sidebarResize, active: false)
                }
        )
        .onChange(of: isResizing) { _, active in
            if !active, resizeState.cancelGesture(restoring: settledWidth) {
                layout.setSidebarWidth(settledWidth)
                model.setChromePin(.sidebarResize, active: false)
            }
        }
        .onHover { isHovered = $0 }
        .onDisappear {
            model.setChromePin(.sourceVisibilityPopover, active: false)
            model.setTransientPresentation(false, owner: "source-visibility")
            resizeState.endGesture()
            model.setChromePin(.sidebarResize, active: false)
        }
        .help("Drag to resize sources")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Resize Sources")
        .accessibilityValue("\(Int(liveWidth)) points wide")
        .accessibilityHint("Drag, or use accessibility increment and decrement actions")
        .accessibilityAdjustableAction { direction in
            let delta: CGFloat = switch direction {
            case .increment: 24
            case .decrement: -24
            @unknown default: 0
            }
            let width = resolvedWidth(for: delta)
            resizeState.setLiveWidth(width)
            layout.setSidebarWidth(width)
            storedSidebarWidth = Double(width)
        }
    }

    private func resolvedWidth(for translation: CGFloat, interfaceScale: CGFloat = 1) -> CGFloat {
        SourcesSidebarSizing.resolvedWidth(
            storedWidth: SourcesSidebarSizing.settledWidth(
                storedWidth: CGFloat(storedSidebarWidth), maximumWidth: maximumWidth
            ),
            dragTranslation: translation,
            maximumWidth: maximumWidth,
            interfaceScale: interfaceScale
        )
    }

    private func updateLiveWidth(for translation: CGFloat, interfaceScale: CGFloat) {
        let width = resolvedWidth(for: translation, interfaceScale: interfaceScale)
        resizeState.setLiveWidth(width)
        layout.setSidebarWidth(width)
    }
}

@MainActor
enum SourcesSidebarScrollerStyle {
    static func apply(to scrollView: NSScrollView) {
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScroller?.controlSize = .mini
    }
}

private struct SourcesSidebarScrollerConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfigurationView {
        ConfigurationView()
    }

    func updateNSView(
        _ view: ConfigurationView,
        context: Context
    ) {
        view.configureEnclosingScrollView()
    }

    final class ConfigurationView: NSView {
        private var hasScheduledRetry = false
        private var retryCount = 0

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            retryCount = 0
            configureEnclosingScrollView()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            retryCount = 0
            configureEnclosingScrollView()
        }

        func configureEnclosingScrollView() {
            guard let scrollView = enclosingScrollView else {
                scheduleRetry()
                return
            }
            hasScheduledRetry = false
            retryCount = 0
            SourcesSidebarScrollerStyle.apply(to: scrollView)
        }

        private func scheduleRetry() {
            guard !hasScheduledRetry, retryCount < 3 else { return }
            hasScheduledRetry = true
            retryCount += 1
            DispatchQueue.main.async { [weak self] in
                self?.hasScheduledRetry = false
                self?.configureEnclosingScrollView()
            }
        }
    }
}

private struct SourcesSearchField: NSViewRepresentable {
    @Binding var text: String
    let onFocusChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField()
        searchField.placeholderString = "Filter sources"
        searchField.controlSize = .small
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = context.coordinator
        return searchField
    }

    func updateNSView(_ searchField: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if searchField.stringValue != text {
            searchField.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SourcesSearchField

        init(parent: SourcesSearchField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.onFocusChanged(true)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else { return }
            parent.text = searchField.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onFocusChanged(false)
        }
    }
}

private struct SourceVisibilityPopover: View {
    @Bindable var model: AppModel
    let hiddenItemCount: Int
    let regexMatchCounts: [String: Int]
    @Binding var previewRegexRuleID: String?

    @State private var newPattern = ""
    @Environment(\.playerTheme) private var theme

    private var visibility: SourceVisibilityConfiguration {
        model.activeSourceVisibility
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("View & Visibility", systemImage: "eye")
                    .font(.headline)
                Spacer()
                if !visibility.isDefault {
                    Button("Reset") {
                        previewRegexRuleID = nil
                        model.resetActiveSourceVisibility()
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("VIEW")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)

                Picker(
                    "View",
                    selection: Binding(
                        get: { visibility.viewMode },
                        set: { mode in
                            model.setActiveSourceViewMode(mode)
                        }
                    )
                ) {
                    ForEach(SourceVisibilityViewMode.allCases, id: \.self) { mode in
                        Label(mode.title, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if visibility.viewMode == .media {
                    Text("Groups local videos by movie, show, season, and extras. Episode order follows numbering.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle(
                    "Show Hidden Items (\(hiddenItemCount))",
                    isOn: Binding(
                        get: { visibility.showsHiddenItems },
                        set: { showsHiddenItems in
                            model.setActiveSourceShowsHiddenItems(showsHiddenItems)
                        }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    regexRules
                    manualRules
                    alwaysShowRules
                }
            }
            .frame(maxHeight: 310)
        }
        .padding(16)
        .frame(width: 360)
        .dynamicPlayerTextStyle(contrastRegion: .leading)
        .playerOverlaySurface(cornerRadius: 18, role: .sidebar)
        .presentationBackground(.clear)
        .preferredColorScheme(theme.preferredColorScheme)
        .environment(\.colorScheme, theme.preferredColorScheme)
        .onDisappear {
            model.setChromePin(.sourceVisibilityPopover, active: false)
            model.setTransientPresentation(false, owner: "source-visibility")
            previewRegexRuleID = nil
            model.setChromePin(.sourceVisibilityPopover, active: false)
        }
    }

    private var regexRules: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("PATTERNS")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Match relative paths")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            ForEach(visibility.regexRules) { rule in
                HStack(spacing: 8) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { rule.isEnabled },
                            set: {
                                model.setActiveSourceRegexRuleEnabled(
                                    rule.id,
                                    isEnabled: $0
                                )
                            }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.checkbox)

                    Circle()
                        .fill(SourceVisibilityRuleColor.color(rule.colorIndex))
                        .frame(width: 8, height: 8)

                    Text(rule.pattern)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .help(rule.pattern)

                    Spacer(minLength: 4)

                    Text("\(regexMatchCounts[rule.id, default: 0])")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Button {
                        if previewRegexRuleID == rule.id {
                            previewRegexRuleID = nil
                        }
                        model.removeActiveSourceRegexRule(rule.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove pattern")
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .background(
                    previewRegexRuleID == rule.id
                        ? SourceVisibilityRuleColor.color(rule.colorIndex).opacity(0.13)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .onHover { hovering in
                    if hovering, rule.isEnabled {
                        previewRegexRuleID = rule.id
                    } else if previewRegexRuleID == rule.id {
                        previewRegexRuleID = nil
                    }
                }
            }

            HStack(spacing: 7) {
                TextField("Regular expression", text: $newPattern)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    .onSubmit(addPattern)

                Button("Add", action: addPattern)
                    .disabled(patternError != nil || newPattern.isEmpty)
            }
            .controlSize(.small)

            if let patternError {
                Text(patternError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else {
                Text("Examples: (?i)(^|/)extras(/|$) or (?i)sample.*\\.mkv$")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var manualRules: some View {
        if !visibility.manuallyHiddenPaths.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text("MANUALLY HIDDEN")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)

                ForEach(visibility.manuallyHiddenPaths.sorted(), id: \.self) { path in
                    visibilityPathRow(
                        path: path,
                        systemImage: "eye.slash",
                        remove: {
                            model.removeActiveSourceManualHide(path)
                        }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var alwaysShowRules: some View {
        if !visibility.alwaysShownPaths.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text("ALWAYS SHOW")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)

                ForEach(visibility.alwaysShownPaths.sorted(), id: \.self) { path in
                    visibilityPathRow(
                        path: path,
                        systemImage: "eye",
                        remove: {
                            model.removeActiveSourceAlwaysShow(path)
                        }
                    )
                }
            }
        }
    }

    private func visibilityPathRow(
        path: String,
        systemImage: String,
        remove: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 12)
                .foregroundStyle(.secondary)
            Text(SourceVisibilityPathLabel.displayName(for: path))
                .font(.caption)
                .lineLimit(1)
                .help(path)
            Spacer()
            Button(action: remove) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Remove visibility override")
        }
        .padding(.horizontal, 6)
    }

    private var patternError: String? {
        let pattern = newPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return nil }
        if pattern.count > 512 {
            return "Patterns are limited to 512 characters."
        }
        if visibility.regexRules.contains(where: { $0.pattern == pattern }) {
            return "That pattern already exists."
        }
        if !SourceVisibilityRegexRule.isValid(pattern: pattern) {
            return "Invalid regular expression."
        }
        return nil
    }

    private func addPattern() {
        guard patternError == nil,
              model.addActiveSourceRegexRule(newPattern)
        else {
            return
        }
        newPattern = ""
    }

}

private enum SourceVisibilityRuleColor {
    static func color(_ index: Int) -> Color {
        switch index % SourceVisibilityRegexRule.colorCount {
        case 0:
            .pink
        case 1:
            .orange
        case 2:
            .yellow
        case 3:
            .mint
        case 4:
            .cyan
        default:
            .purple
        }
    }
}

private enum SourceVisibilityPathLabel {
    static func displayName(for path: String) -> String {
        let url = URL(fileURLWithPath: path, isDirectory: false)
        let parent = url.deletingLastPathComponent().lastPathComponent
        guard !parent.isEmpty else { return url.lastPathComponent }
        return "\(parent)/\(url.lastPathComponent)"
    }
}

private struct SourceFolderRow: View {
    let url: URL
    let depth: Int
    let isRoot: Bool
    let isExpanded: Bool
    let isLoading: Bool
    let hasError: Bool
    let visibility: SourceRowVisibility?
    let onToggleVisibility: () -> Void
    let onToggle: () -> Void

    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onToggle) {
                HStack(spacing: 7) {
                    Color.clear
                        .frame(width: CGFloat(depth) * 14)

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)

                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                        .foregroundStyle(.primary)

                    Text(url.lastPathComponent)
                        .font(.callout.weight(isRoot ? .semibold : .regular))
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)

                    Spacer(minLength: 4)

                    if let visibility, !visibility.regexMatches.isEmpty {
                        SourceVisibilityMatchDots(matches: visibility.regexMatches)
                    }

                    if isLoading {
                        ProgressView()
                            .controlSize(.mini)
                    } else if hasError {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 7)
                .padding(.leading, 7)
                .padding(.trailing, 34)
                .contentShape(Rectangle())
                .background(rowBackground, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            if (isHovering || visibility != nil),
               visibility?.isInherited != true
            {
                SourceVisibilityEyeButton(
                    isHidden: visibility != nil,
                    action: onToggleVisibility
                )
                .padding(.trailing, 6)
            }
        }
        .opacity(visibility == nil ? 1 : 0.46)
        .onHover { isHovering = $0 }
        .help(url.path)
        .accessibilityLabel("\(isRoot ? "Source" : "Folder") \(url.lastPathComponent)")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }

    private var rowBackground: Color {
        isHovering ? Color.primary.opacity(0.075) : .clear
    }
}

private struct SourceFileRow: View {
    let model: AppModel
    let url: URL
    let dateAdded: Date?
    let title: String
    let contextLabel: String?
    let depth: Int
    let isCurrent: Bool
    let visibility: SourceRowVisibility?
    let isProgressRefreshActive: Bool
    let onToggleVisibility: () -> Void
    let onPlay: () -> Void

    @State private var isHovering = false
    @State private var progress: MediaPlaybackProgress?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isCompleted: Bool {
        progress?.isCompleted == true || (progress?.fraction ?? 0) > 0.9
    }

    private var displayedFraction: Double {
        isCompleted ? 1 : (progress?.fraction ?? 0)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onPlay) {
                HStack(spacing: 9) {
                    Color.clear
                        .frame(width: CGFloat(depth) * 14)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(isCurrent ? Color.primary.opacity(0.9) : Color.clear)
                        .frame(width: 3)

                    statusIcon

                    VStack(alignment: .leading, spacing: 6) {
                        Text(title)
                            .font(.callout.weight(isCurrent ? .semibold : .regular))
                            .lineLimit(1)
                            .multilineTextAlignment(.leading)

                        HStack(spacing: 7) {
                            if let contextLabel {
                                Text(contextLabel)
                            } else if let dateAdded {
                                Text(
                                    "Added \(dateAdded.formatted(.dateTime.month(.abbreviated).day()))"
                                )
                            } else {
                                Text("Date unavailable")
                            }

                            Spacer(minLength: 2)

                            if let visibility, !visibility.regexMatches.isEmpty {
                                SourceVisibilityMatchDots(
                                    matches: visibility.regexMatches
                                )
                            }

                            ProgressBar(
                                fraction: displayedFraction,
                                isCompleted: isCompleted
                            )
                            .frame(minWidth: 42, idealWidth: 64, maxWidth: 82)

                            Text(progressLabel)
                                .font(.caption2.monospacedDigit().weight(.medium))
                                .foregroundStyle(.primary)
                                .opacity(isCompleted ? 1 : 0.7)
                                .frame(minWidth: 29, alignment: .trailing)
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 8)
                    .padding(.trailing, 34)
                }
                .contentShape(Rectangle())
                .background(rowBackground, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .allowsHitTesting(visibility == nil)

            if (isHovering || visibility != nil),
               visibility?.isInherited != true
            {
                SourceVisibilityEyeButton(
                    isHidden: visibility != nil,
                    action: onToggleVisibility
                )
                .padding(.trailing, 6)
            }
        }
        .opacity(visibility == nil ? 1 : 0.46)
        .animation(
            PlatinumMotion.stateMorph(reduceMotion: reduceMotion),
            value: isCurrent
        )
        .onHover { isHovering = $0 }
        .task(id: SourceProgressTaskID(
            fileID: SourceTreeIdentity.fileID(for: url),
            isRefreshActive: isProgressRefreshActive
        )) {
            refreshProgress()
            guard isProgressRefreshActive else { return }

            while !Task.isCancelled {
                try? await Task.sleep(
                    for: PlaybackChromeRefreshPolicy.sourceProgressInterval
                )
                guard !Task.isCancelled else { return }
                refreshProgress()
            }
        }
        .help(url.path)
        .accessibilityLabel("\(title), \(progressLabel)")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityAction(named: "Play", onPlay)
    }

    private func refreshProgress() {
        let latest = model.player.playbackProgress(for: url)
        if progress != latest {
            progress = latest
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        Image(systemName: statusSystemImage)
            .foregroundStyle(.primary)
            .contentTransition(.symbolEffect(.replace))
            .animation(
                PlatinumMotion.stateMorph(reduceMotion: reduceMotion),
                value: statusSystemImage
            )
    }

    private var statusSystemImage: String {
        if isCurrent { return "play.fill" }
        if isCompleted { return "checkmark.circle.fill" }
        return "play.circle"
    }

    private var rowBackground: Color {
        if isCurrent { return Color.primary.opacity(0.13) }
        if isHovering { return Color.primary.opacity(0.075) }
        return .clear
    }

    private var progressLabel: String {
        if isCompleted { return "Done" }
        return "\(Int(displayedFraction * 100))%"
    }
}

private struct SourceVisibilityEyeButton: View {
    let isHidden: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isHidden ? "eye" : "eye.slash")
                .font(.caption.weight(.semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .background(
                    Color.primary.opacity(isHidden ? 0.13 : 0.075),
                    in: RoundedRectangle(cornerRadius: 6)
                )
        }
        .buttonStyle(.plain)
        .help(isHidden ? "Always show this source" : "Hide this source")
        .accessibilityLabel(
            isHidden ? "Always show this source" : "Hide this source"
        )
    }
}

private struct SourceVisibilityMatchDots: View {
    let matches: [SourceVisibilityRegexMatch]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(matches.prefix(3).enumerated()), id: \.offset) {
                _, match in
                Circle()
                    .fill(SourceVisibilityRuleColor.color(match.colorIndex))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityLabel(
            "\(matches.count) matching visibility "
                + (matches.count == 1 ? "rule" : "rules")
        )
    }
}

private struct SourceTreeMessageRow: View {
    let message: String
    let depth: Int

    var body: some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, CGFloat(depth) * 14 + 34)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(message)
    }
}

private struct SourceProgressTaskID: Equatable {
    let fileID: String
    let isRefreshActive: Bool
}

private struct ProgressBar: View {
    let fraction: Double
    let isCompleted: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.primary.opacity(0.13))
                Capsule()
                    .fill(isCompleted ? Color.green : Color.primary.opacity(0.82))
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                    .transaction { transaction in
                        transaction.animation = nil
                    }
            }
        }
        .frame(height: 3)
        .overlay {
            Capsule()
                .stroke(
                    Color.green.opacity(isCompleted ? 0.34 : 0),
                    lineWidth: 1
                )
                .scaleEffect(isCompleted ? 1 : 0.96)
                .animation(
                    PlatinumMotion.stateMorph(reduceMotion: reduceMotion),
                    value: isCompleted
                )
        }
        .accessibilityHidden(true)
    }
}

struct SourceTreeEntry: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case folder
        case media
    }

    let url: URL
    let kind: Kind
    let dateAdded: Date?
    let creationDate: Date?
    let visibilityPath: String?
    var recognizedMedia: RecognizedMediaName? = nil

    init(
        url: URL,
        kind: Kind,
        dateAdded: Date?,
        creationDate: Date?,
        visibilityPath: String? = nil
    ) {
        self.url = url
        self.kind = kind
        self.dateAdded = dateAdded
        self.creationDate = creationDate
        self.visibilityPath = visibilityPath
    }
}

struct SourceVisibilityRegexMatch: Equatable, Sendable {
    let id: String
    let colorIndex: Int
}

enum SourceVisibilityHideMatch: Equatable, Sendable {
    case manual
    case regex(SourceVisibilityRegexMatch)
}

struct SourceVisibilityEvaluation: Equatable, Sendable {
    let hiddenMatches: [SourceVisibilityHideMatch]
    let regexMatches: [SourceVisibilityRegexMatch]
}

struct SourceRowVisibility: Equatable, Sendable {
    let matches: [SourceVisibilityHideMatch]
    let isInherited: Bool

    var regexMatches: [SourceVisibilityRegexMatch] {
        matches.compactMap { match in
            guard case let .regex(regexMatch) = match else { return nil }
            return regexMatch
        }
    }

    var isManual: Bool {
        matches.contains(.manual)
    }
}

struct SourceVisibilityMatcher {
    private struct CompiledRule {
        let match: SourceVisibilityRegexMatch
        let expression: NSRegularExpression
    }

    private let configuration: SourceVisibilityConfiguration
    private let rootPaths: [String]
    private let compiledRules: [CompiledRule]
    private let rootEvaluations: [String: SourceVisibilityEvaluation]

    init(
        configuration: SourceVisibilityConfiguration,
        roots: [URL]
    ) {
        self.configuration = configuration
        let rootPaths = roots.compactMap(SourceVisibilityPath.normalized)
        let compiledRules: [CompiledRule] =
            configuration.regexRules.compactMap { rule in
            guard rule.isEnabled,
                  let expression = try? NSRegularExpression(pattern: rule.pattern)
            else {
                return nil
            }
            return CompiledRule(
                match: SourceVisibilityRegexMatch(
                    id: rule.id,
                    colorIndex: rule.colorIndex
                ),
                expression: expression
            )
        }
        self.rootPaths = rootPaths
        self.compiledRules = compiledRules
        rootEvaluations = Dictionary(uniqueKeysWithValues: rootPaths.map { path in
            (
                path,
                Self.evaluate(
                    normalizedPath: path,
                    candidate: URL(fileURLWithPath: path, isDirectory: false).lastPathComponent,
                    configuration: configuration,
                    compiledRules: compiledRules
                )
            )
        })
    }

    func evaluate(_ url: URL) -> SourceVisibilityEvaluation {
        guard let normalizedPath = SourceVisibilityPath.normalized(url)
        else {
            return SourceVisibilityEvaluation(
                hiddenMatches: [],
                regexMatches: []
            )
        }
        return evaluate(normalizedPath: normalizedPath)
    }

    func evaluate(
        normalizedPath: String
    ) -> SourceVisibilityEvaluation {
        Self.evaluate(
            normalizedPath: normalizedPath,
            candidate: relativePath(normalizedPath: normalizedPath),
            configuration: configuration,
            compiledRules: compiledRules
        )
    }

    private static func evaluate(
        normalizedPath: String,
        candidate: String,
        configuration: SourceVisibilityConfiguration,
        compiledRules: [CompiledRule]
    ) -> SourceVisibilityEvaluation {
        let range = NSRange(candidate.startIndex..., in: candidate)
        let regexMatches = compiledRules.compactMap { rule in
            var matched = false
            rule.expression.enumerateMatches(in: candidate, options: [.reportProgress], range: range) {
                result, _, stop in
                if result != nil { matched = true }
                if matched || Task.isCancelled { stop.pointee = true }
            }
            return matched ? rule.match : nil
        }

        if configuration.manuallyHiddenPaths.contains(normalizedPath) {
            return SourceVisibilityEvaluation(
                hiddenMatches: [.manual] + regexMatches.map {
                    .regex($0)
                },
                regexMatches: regexMatches
            )
        }
        if configuration.alwaysShownPaths.contains(normalizedPath) {
            return SourceVisibilityEvaluation(
                hiddenMatches: [],
                regexMatches: regexMatches
            )
        }
        return SourceVisibilityEvaluation(
            hiddenMatches: regexMatches.map { .regex($0) },
            regexMatches: regexMatches
        )
    }

    func evaluateIncludingAncestors(_ url: URL) -> SourceVisibilityEvaluation {
        guard let normalizedPath = SourceVisibilityPath.normalized(url) else {
            return SourceVisibilityEvaluation(
                hiddenMatches: [],
                regexMatches: []
            )
        }
        return evaluateIncludingAncestors(normalizedPath: normalizedPath)
    }

    func evaluateIncludingAncestors(
        normalizedPath: String
    ) -> SourceVisibilityEvaluation {
        guard let rootPath = matchingRootPath(for: normalizedPath) else {
            return evaluate(normalizedPath: normalizedPath)
        }
        return evaluateIncludingAncestors(
            normalizedPath: normalizedPath,
            rootPath: rootPath
        )
    }

    private func evaluateIncludingAncestors(
        normalizedPath: String,
        rootPath: String
    ) -> SourceVisibilityEvaluation {
        let direct = evaluate(normalizedPath: normalizedPath)

        var regexMatches = direct.regexMatches
        var ancestorPath = URL(fileURLWithPath: normalizedPath, isDirectory: false)
            .deletingLastPathComponent()
            .path
        while ancestorPath.count >= rootPath.count,
              ancestorPath == rootPath
                || ancestorPath.hasPrefix(rootPath + "/")
        {
            let ancestor = ancestorPath == rootPath
                ? rootEvaluations[rootPath] ?? evaluate(
                    normalizedPath: ancestorPath
                )
                : evaluate(normalizedPath: ancestorPath)
            for match in ancestor.regexMatches where !regexMatches.contains(match) {
                regexMatches.append(match)
            }
            if !ancestor.hiddenMatches.isEmpty {
                return SourceVisibilityEvaluation(
                    hiddenMatches: ancestor.hiddenMatches,
                    regexMatches: regexMatches
                )
            }
            if ancestorPath == rootPath {
                break
            }
            ancestorPath = URL(fileURLWithPath: ancestorPath, isDirectory: false)
                .deletingLastPathComponent()
                .path
        }

        return SourceVisibilityEvaluation(
            hiddenMatches: direct.hiddenMatches,
            regexMatches: regexMatches
        )
    }

    func relativePath(for url: URL) -> String {
        guard let normalizedPath = SourceVisibilityPath.normalized(url)
        else {
            return url.lastPathComponent
        }
        return relativePath(normalizedPath: normalizedPath)
    }

    func relativePath(normalizedPath: String) -> String {
        let matchingRoot = matchingRootPath(for: normalizedPath)

        guard let matchingRoot else {
            return URL(fileURLWithPath: normalizedPath, isDirectory: false).lastPathComponent
        }
        guard normalizedPath != matchingRoot else {
            return URL(fileURLWithPath: matchingRoot, isDirectory: false).lastPathComponent
        }
        return String(normalizedPath.dropFirst(matchingRoot.count + 1))
    }

    private func matchingRootPath(for normalizedPath: String) -> String? {
        rootPaths
            .filter { rootPath in
                normalizedPath == rootPath
                    || normalizedPath.hasPrefix(rootPath + "/")
            }
            .max { $0.count < $1.count }
    }
}

enum SourceVisibilityProjection {
    static func includes(
        _ kind: SourceTreeEntry.Kind?,
        in viewMode: SourceVisibilityViewMode
    ) -> Bool {
        guard let kind else { return true }
        return switch (viewMode, kind) {
        case (.tree, _), (.filesOnly, .media), (.media, .media), (.foldersOnly, .folder):
            true
        case (.filesOnly, .folder), (.media, .folder), (.foldersOnly, .media):
            false
        }
    }
}

enum SourceTreeSortCriterion: String, CaseIterable, Identifiable, Sendable {
    case type
    case dateCreated
    case name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .type:
            "Type"
        case .dateCreated:
            "Date Created"
        case .name:
            "Name"
        }
    }

    var systemImage: String {
        switch self {
        case .type:
            "square.grid.2x2"
        case .dateCreated:
            "calendar"
        case .name:
            "textformat"
        }
    }
}

enum SourceTreeSortDirection: String, CaseIterable, Sendable {
    case off
    case ascending
    case descending

    var next: Self {
        switch self {
        case .off:
            .ascending
        case .ascending:
            .descending
        case .descending:
            .off
        }
    }

    var title: String {
        switch self {
        case .off:
            "Off"
        case .ascending:
            "Ascending"
        case .descending:
            "Descending"
        }
    }

    var systemImage: String? {
        switch self {
        case .off:
            nil
        case .ascending:
            "arrow.up"
        case .descending:
            "arrow.down"
        }
    }

    static func resolve(_ rawValue: String) -> Self {
        Self(rawValue: rawValue) ?? .off
    }
}

struct SourceTreeSortConfiguration: Equatable, Sendable {
    let name: SourceTreeSortDirection
    let dateCreated: SourceTreeSortDirection
    let type: SourceTreeSortDirection

    func direction(
        for criterion: SourceTreeSortCriterion
    ) -> SourceTreeSortDirection {
        switch criterion {
        case .type:
            type
        case .dateCreated:
            dateCreated
        case .name:
            name
        }
    }
}

enum SourceTreeSorting {
    private static let criterionPrecedence: [SourceTreeSortCriterion] = [
        .type,
        .dateCreated,
        .name,
    ]

    static func sorted(
        _ entries: [SourceTreeEntry],
        using configuration: SourceTreeSortConfiguration
    ) -> [SourceTreeEntry] {
        entries
            .enumerated()
            .sorted { left, right in
                for criterion in criterionPrecedence {
                    let direction = configuration.direction(for: criterion)
                    guard direction != .off else { continue }
                    if let precedes = orderedBefore(
                        left.element,
                        right.element,
                        by: criterion,
                        direction: direction
                    ) {
                        return precedes
                    }
                }
                return left.offset < right.offset
            }
            .map(\.element)
    }

    private static func orderedBefore(
        _ left: SourceTreeEntry,
        _ right: SourceTreeEntry,
        by criterion: SourceTreeSortCriterion,
        direction: SourceTreeSortDirection
    ) -> Bool? {
        switch criterion {
        case .type:
            guard left.kind != right.kind else { return nil }
            let foldersFirst = direction == .ascending
            return foldersFirst
                ? left.kind == .folder
                : left.kind == .media

        case .dateCreated:
            switch (left.creationDate, right.creationDate) {
            case let (leftDate?, rightDate?) where leftDate != rightDate:
                return direction == .ascending
                    ? leftDate < rightDate
                    : leftDate > rightDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return nil
            }

        case .name:
            let comparison = naturalComparison(left.url, right.url)
            guard comparison != .orderedSame else { return nil }
            return direction == .ascending
                ? comparison == .orderedAscending
                : comparison == .orderedDescending
        }
    }

    private static func naturalComparison(
        _ left: URL,
        _ right: URL
    ) -> ComparisonResult {
        let nameComparison = left.lastPathComponent.localizedStandardCompare(
            right.lastPathComponent
        )
        guard nameComparison == .orderedSame else { return nameComparison }
        return left.path.compare(right.path, options: [.literal])
    }
}

struct SourceDirectoryListing: Equatable, Sendable {
    let entries: [SourceTreeEntry]
    let errorMessage: String?
}

enum SourceDirectoryLoader {
    static func load(_ folderURL: URL) async -> SourceDirectoryListing {
        do {
            return try await SourcePreparationExecutor.shared.performWhenAvailable { check in
                read(folderURL, checkCancellation: check)
            }
        } catch {
            return SourceDirectoryListing(entries: [], errorMessage: error.localizedDescription)
        }
    }

    nonisolated static func read(
        _ folderURL: URL, checkCancellation: @Sendable () throws -> Void = { try Task.checkCancellation() }
    ) -> SourceDirectoryListing {
        do {
            try checkCancellation()
            let folderURL = NormalizedFileURL.resolveFilesystemIdentity(folderURL) ?? folderURL
            try checkCancellation()
            let urls = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .isPackageKey,
                    .addedToDirectoryDateKey,
                    .creationDateKey,
                    .contentModificationDateKey,
                ],
                options: [.skipsHiddenFiles]
            )
            let entries = try urls.compactMap { originalURL -> SourceTreeEntry? in
                try checkCancellation()
                let url = NormalizedFileURL.resolveFilesystemIdentity(originalURL) ?? originalURL
                try checkCancellation()
                let values = try? originalURL.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .isPackageKey,
                    .addedToDirectoryDateKey,
                    .creationDateKey,
                    .contentModificationDateKey,
                ])
                if values?.isDirectory == true,
                   values?.isSymbolicLink != true,
                   values?.isPackage != true
                {
                    return SourceTreeEntry(
                        url: url,
                        kind: .folder,
                        dateAdded: nil,
                        creationDate: values?.creationDate
                            ?? values?.contentModificationDate,
                        visibilityPath: SourceVisibilityPath.normalized(url)
                    )
                }
                guard values?.isRegularFile == true,
                      MediaFileSupport.isSupportedMediaFile(url)
                else {
                    return nil
                }
                return SourceTreeEntry(
                    url: url,
                    kind: .media,
                    dateAdded: values?.addedToDirectoryDate
                        ?? values?.creationDate
                        ?? values?.contentModificationDate,
                    creationDate: values?.creationDate
                        ?? values?.addedToDirectoryDate
                        ?? values?.contentModificationDate,
                    visibilityPath: SourceVisibilityPath.normalized(url)
                )
            }
            return SourceDirectoryListing(entries: entries, errorMessage: nil)
        } catch {
            return SourceDirectoryListing(
                entries: [],
                errorMessage: "Folder unavailable"
            )
        }
    }
}

enum SourceRecursiveMediaLoader {
    static func load(_ roots: [URL], files: [URL] = [], readsMetadata: Bool = false) async -> Result<[SourceTreeEntry], Error> {
        do {
            return .success(try await SourcePreparationExecutor.shared.performWhenAvailable { check in
                read(roots, files: files, readsMetadata: readsMetadata, checkCancellation: check)
            })
        } catch { return .failure(error) }
    }

    nonisolated static func read(
        _ roots: [URL], files: [URL] = [], readsMetadata: Bool = false,
        checkCancellation: @Sendable () throws -> Void = { try Task.checkCancellation() }
    ) -> [SourceTreeEntry] {
        var entries: [SourceTreeEntry] = []
        var seenPaths: Set<String> = []
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isPackageKey,
            .addedToDirectoryDateKey,
            .creationDateKey,
            .contentModificationDateKey,
        ]

        for originalRoot in roots {
            guard (try? checkCancellation()) != nil else { return [] }
            let root = NormalizedFileURL.resolveFilesystemIdentity(originalRoot) ?? originalRoot
            guard (try? checkCancellation()) != nil,
                  let enumerator = FileManager.default.enumerator(
                      at: root,
                      includingPropertiesForKeys: keys,
                      options: [.skipsHiddenFiles, .skipsPackageDescendants],
                      errorHandler: { _, _ in true }
                  )
            else {
                continue
            }

            while let originalURL = enumerator.nextObject() as? URL {
                guard (try? checkCancellation()) != nil else { return [] }
                let url = NormalizedFileURL.resolveFilesystemIdentity(originalURL) ?? originalURL
                guard (try? checkCancellation()) != nil else { return [] }
                let values = try? originalURL.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
                    if values?.isSymbolicLink == true || values?.isPackage == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard values?.isRegularFile == true,
                      MediaFileSupport.isSupportedMediaFile(url),
                      let path = SourceVisibilityPath.normalized(url),
                      seenPaths.insert(path).inserted
                else {
                    continue
                }
                entries.append(SourceTreeEntry(
                    url: url,
                    kind: .media,
                    dateAdded: values?.addedToDirectoryDate
                        ?? values?.creationDate
                        ?? values?.contentModificationDate,
                    creationDate: values?.creationDate
                        ?? values?.addedToDirectoryDate
                        ?? values?.contentModificationDate,
                    visibilityPath: path
                ))
            }
        }
        for file in files {
            guard (try? checkCancellation()) != nil else { return [] }
            let url = NormalizedFileURL.resolveFilesystemIdentity(file) ?? file
            guard let path = SourceVisibilityPath.normalized(url), seenPaths.insert(path).inserted else { continue }
            entries.append(SourceTreeEntry(url: url, kind: .media, dateAdded: nil,
                creationDate: nil, visibilityPath: path))
        }
        if readsMetadata {
            let reader = MediaSidecarReader()
            let metadataRoots = roots.map { NormalizedFileURL.resolveFilesystemIdentity($0) ?? $0 }
                .sorted { $0.path.count < $1.path.count }
            for index in entries.indices {
                guard (try? checkCancellation()) != nil else { return [] }
                let file = entries[index].url
                let root = metadataRoots.first { file.path.hasPrefix($0.path + "/") }
                    ?? file.deletingLastPathComponent()
                do {
                    entries[index].recognizedMedia = try reader.recognize(file, within: root, checkCancellation: checkCancellation)
                } catch { return [] }
            }
        }
        return entries
    }
}

struct SourceTreeDisplayRow: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case folder(isRoot: Bool)
        case media(dateAdded: Date?)
        case message(String)
        case mediaSection

        var itemKind: SourceTreeEntry.Kind? {
            switch self {
            case .folder:
                .folder
            case .media:
                .media
            case .message, .mediaSection:
                nil
            }
        }
    }

    let id: String
    let folderID: String
    let url: URL
    let displayName: String
    var contextLabel: String? = nil
    var recognizedMedia: RecognizedMediaName? = nil
    var visibilityPath: String? = nil
    let depth: Int
    let ancestorIDs: [String]
    let kind: Kind
    var visibility: SourceRowVisibility? = nil
}

enum SourceTreeIdentity {
    static func folderID(for url: URL) -> String {
        normalizedPath(for: url)
    }

    static func fileID(for url: URL) -> String {
        normalizedPath(for: url)
    }

    static func path(fromFolderID id: String) -> String {
        id
    }

    static func isFolderID(_ id: String, inside root: URL) -> Bool {
        let rootPath = normalizedPath(for: root)
        return id == rootPath || id.hasPrefix(rootPath + "/")
    }

    private static func normalizedPath(for url: URL) -> String {
        (NormalizedFileURL.normalize(url) ?? url.absoluteURL.standardized).path
    }
}

struct SourcesSidebarExpansionSnapshot: Equatable, Sendable {
    let expandedFolderIDs: Set<String>
    let knownSourceFolderIDs: Set<String>
}

enum SourcesSidebarExpansionStore {
    static let defaultsKey = "Superplayr.sources-sidebar-expansion.v1"

    private struct Payload: Codable {
        let version: Int
        let expandedFolderIDs: [String]
        let knownSourceFolderIDs: [String]
    }

    static func restore(from data: Data?) -> SourcesSidebarExpansionSnapshot? {
        guard let data,
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == 1
        else {
            return nil
        }
        return SourcesSidebarExpansionSnapshot(
            expandedFolderIDs: normalizedFolderIDs(payload.expandedFolderIDs),
            knownSourceFolderIDs: normalizedFolderIDs(payload.knownSourceFolderIDs)
        )
    }

    static func persist(
        _ snapshot: SourcesSidebarExpansionSnapshot,
        defaults: UserDefaults = .standard
    ) {
        let payload = Payload(
            version: 1,
            expandedFolderIDs: snapshot.expandedFolderIDs.sorted(),
            knownSourceFolderIDs: snapshot.knownSourceFolderIDs.sorted()
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    private static func normalizedFolderIDs(_ ids: [String]) -> Set<String> {
        Set(ids.compactMap { id in
            guard id.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: id, isDirectory: true)
                .absoluteURL.standardized
                .path
        })
    }
}

enum SourcesSidebarSizing {
    static let minimumContainerWidth: CGFloat = 900

    static func isAvailable(in containerWidth: CGFloat) -> Bool {
        containerWidth >= minimumContainerWidth
    }

    static let minimumWidth: CGFloat = 300
    static let defaultWidth: CGFloat = 360
    static let absoluteMaximumWidth: CGFloat = 720

    static func maximumWidth(for containerWidth: CGFloat) -> CGFloat {
        max(
            minimumWidth,
            min(
                absoluteMaximumWidth,
                containerWidth * 0.62,
                containerWidth
                    - SourcesSidebarLayoutPolicy.minimumUncoveredChromeWidth
                    - SourcesSidebarLayoutPolicy.horizontalPadding
            )
        )
    }

    static func resolvedWidth(
        storedWidth: CGFloat,
        dragTranslation: CGFloat,
        maximumWidth: CGFloat,
        interfaceScale: CGFloat = 1
    ) -> CGFloat {
        min(
            max(storedWidth + dragTranslation / interfaceScale, minimumWidth),
            max(maximumWidth, minimumWidth)
        )
    }

    static func settledWidth(
        storedWidth: CGFloat,
        maximumWidth: CGFloat
    ) -> CGFloat {
        resolvedWidth(
            storedWidth: storedWidth,
            dragTranslation: 0,
            maximumWidth: maximumWidth
        )
    }
}

enum SourcesSidebarLayoutPolicy {
    static let outerPadding: CGFloat = 10
    static let horizontalPadding = outerPadding * 2
    static let minimumUncoveredChromeWidth: CGFloat = 332

    static func occupiedWidth(forSidebarWidth sidebarWidth: CGFloat) -> CGFloat {
        max(0, sidebarWidth) + horizontalPadding
    }
}
