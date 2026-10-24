import SwiftUI

/// The query tabs above the editor, with a button to open another.
struct QueryTabBar: View {
    var model: ExplorerModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.tabs) { tab in
                        TabButton(tab: tab, isSelected: tab.id == model.selectedTabID, canClose: model.tabs.count > 1) {
                            model.selectedTabID = tab.id
                        } close: {
                            model.closeTab(tab.id)
                        }
                        .contextMenu {
                            Button("Duplicate Tab") { model.newTab(soql: tab.soql) }
                            Divider()
                            Button("Close Tab") { model.closeTab(tab.id) }
                            Button("Close Other Tabs") { model.closeOtherTabs(than: tab.id) }
                                .disabled(model.tabs.count < 2)
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
            Button {
                model.newTab()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New Query Tab (⌘T)")
            .padding(.horizontal, 8)
        }
        .frame(height: 30)
    }
}

private struct TabButton: View {
    let tab: QueryTab
    let isSelected: Bool
    let canClose: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            if tab.isQuerying {
                ProgressView().controlSize(.mini)
            }
            Text(tab.title)
                .lineLimit(1)
            if canClose {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.borderless)
                .opacity(isHovering || isSelected ? 1 : 0)
                .help("Close Tab")
                .accessibilityLabel("Close \(tab.title)")
            }
        }
        .font(.callout)
        .padding(.leading, 10)
        .padding(.trailing, canClose ? 6 : 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : isHovering ? Color.primary.opacity(0.06) : .clear)
        )
        .foregroundStyle(isSelected ? .primary : .secondary)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
        .help(tab.soql)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("queryTab")
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
