import SwiftUI
import IlliquidCore

struct OpenVideoTabBar: View {
    @Bindable var model: AppModel
    @Environment(\.playerTheme) private var theme

    var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(model.openVideoTabs.items) { tab in
                            HStack(spacing: 6) {
                                Button { model.selectOpenVideoTab(tab.id) } label: {
                                    Label(tab.title, systemImage: "film")
                                        .font(.system(size: 12, weight: tab.id == model.openVideoTabs.selectedID ? .semibold : .regular))
                                        .lineLimit(1)
                                        .frame(maxWidth: 220, alignment: .leading)
                                        .padding(.vertical, 5)
                                        .padding(.leading, 10)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(tab.id == model.openVideoTabs.selectedID ? .isSelected : [])
                                .help(tab.source.url.isFileURL ? tab.source.url.path : tab.source.url.absoluteString)
                                Button { model.closeOpenVideoTab(tab.id) } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 10, weight: .semibold))
                                        .frame(width: 24, height: 24)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Close \(tab.title)")
                                .help("Close video tab")
                            }
                            .foregroundStyle(tab.id == model.openVideoTabs.selectedID ? theme.primaryColor : theme.secondaryColor)
                            .background(tab.id == model.openVideoTabs.selectedID ? theme.selectedFillColor : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .id(tab.id)
                        }
                    }
                }
            }
            .frame(height: 28)
            .onChange(of: model.openVideoTabs.selectedID, initial: true) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
        .environment(\.colorScheme, theme.preferredColorScheme)
        .accessibilityIdentifier("open-video-tabs")
        .onHover { hovering in
            model.setChromePin(.pointerOverChrome, active: hovering)
            model.setPointerRegion(hovering ? .chrome : .video)
        }
    }
}
