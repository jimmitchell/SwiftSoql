import AppKit
import SwiftUI

/// A horizontal divider to drag, changing the height of the pane above it, or with
/// `resizesPaneBelow`, the pane below. Workspaces use these instead of VSplitView, which kept
/// windows from getting narrow.
struct SplitDivider: View {
    @Binding var height: Double
    let range: ClosedRange<Double>
    var resizesPaneBelow = false
    @State private var startHeight: Double?

    var body: some View {
        Divider()
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let start = startHeight ?? height.clamped(to: range)
                    startHeight = start
                    let change = resizesPaneBelow ? -drag.translation.height : drag.translation.height
                    height = (start + change).clamped(to: range)
                }
                .onEnded { _ in startHeight = nil })
            .accessibilityHidden(true)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
