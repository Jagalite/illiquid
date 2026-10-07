import SwiftUI
import IlliquidCore

struct SourceSidebarTabs: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(model.sourceTabs) { tab in
                            SourceSidebarTab(model: model, tab: tab).id(tab.id)
                        }
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity)
                .onChange(of: model.activeSourceTabID, initial: true) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.16)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            Button(action: model.createSourceTab) {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Folder Tab")
            .accessibilityLabel("New Source Tab")
        }
        .frame(height: 28)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .accessibilityIdentifier("source-sidebar-tabs")
    }
}

private struct SourceSidebarTab: View {
    @Bindable var model: AppModel
    let tab: SourceTab
    @State private var isHovering = false
    @Environment(\.playerTheme) private var theme

    private var isSelected: Bool {
        tab.id == model.activeSourceTabID
    }

    private var showsCloseButton: Bool {
        isSelected || isHovering
    }

    var body: some View {
        HStack(spacing: 2) {
            Button {
                model.selectSourceTab(tab.id)
            } label: {
                HStack(spacing: 5) {
                    Image(
                        systemName: isSelected
                            ? "rectangle.stack.fill"
                            : "rectangle.stack"
                    )
                        .font(.caption)

                    Text(tab.displayName)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if model.isCurrentMediaInsideSourceTab(tab) {
                        Circle()
                            .fill(theme.playingIndicatorColor)
                            .frame(width: 5, height: 5)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: 102, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                model.closeSourceTab(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .frame(width: 15, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(showsCloseButton ? 0.72 : 0)
            .allowsHitTesting(showsCloseButton)
            .accessibilityLabel("Close \(tab.displayName) Tab")
        }
        .padding(.leading, 8)
        .padding(.trailing, 3)
        .frame(height: 24)
        .dynamicPlayerTextStyle(appliesControlTint: true)
        .opacity(isSelected ? 1 : 0.96)
        .background(
            isSelected
                ? theme.selectedFillColor
                : theme.hoverFillColor.opacity(isHovering ? 1 : 0),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(
                    isSelected ? theme.selectedEdgeColor : .clear,
                    lineWidth: 0.5
                )
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            if let onlyItem = tab.items.only {
                Button("Reveal in Finder") {
                    model.revealSourceInFinder(onlyItem.url)
                }
                Divider()
            }
            Button("Close Tab") {
                model.closeSourceTab(tab.id)
            }
        }
        .help(tab.displayName)
        .accessibilityElement(children: .contain)
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
