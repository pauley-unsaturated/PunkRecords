import SwiftUI
import AppKit

/// A lightweight, caret-anchored completion popover for `[[` wikilink
/// autocomplete. Hosts a SwiftUI list inside a non-activating NSPanel so the
/// editor keeps focus and keystrokes keep flowing into the `[[query`.
///
/// The owning text view forwards ↑/↓/Enter/Esc here while `isVisible`.
@MainActor
final class WikilinkCompletionController {
    private var panel: NSPanel?
    private let model = WikilinkCompletionModel()

    /// Invoked with the chosen title when the user accepts a completion.
    var onAccept: ((String) -> Void)?

    var isVisible: Bool { panel?.isVisible == true }

    /// Show or update the popover with `titles`, anchored at `screenRect`
    /// (the caret rect in screen coordinates). Hides if `titles` is empty.
    func show(titles: [String], at screenRect: NSRect, relativeTo parent: NSWindow?) {
        guard !titles.isEmpty else { hide(); return }
        model.titles = titles
        if model.selectedIndex >= titles.count { model.selectedIndex = 0 }

        let panel = panel ?? makePanel()
        self.panel = panel

        // Size to content (cap the visible rows).
        let rowHeight: CGFloat = 24
        let visibleRows = min(titles.count, 8)
        let height = CGFloat(visibleRows) * rowHeight + 8
        let width: CGFloat = 280
        panel.setContentSize(NSSize(width: width, height: height))

        // Position just below the caret; flip above if it would clip offscreen.
        var origin = NSPoint(x: screenRect.minX, y: screenRect.minY - height - 2)
        if let screen = parent?.screen ?? NSScreen.main, origin.y < screen.visibleFrame.minY {
            origin.y = screenRect.maxY + 2
        }
        panel.setFrameOrigin(origin)

        if panel.parent == nil, let parent {
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func hide() {
        model.selectedIndex = 0
        panel?.orderOut(nil)
        if let panel, let parent = panel.parent {
            parent.removeChildWindow(panel)
        }
    }

    func moveDown() {
        guard !model.titles.isEmpty else { return }
        model.selectedIndex = min(model.selectedIndex + 1, model.titles.count - 1)
    }

    func moveUp() {
        guard !model.titles.isEmpty else { return }
        model.selectedIndex = max(model.selectedIndex - 1, 0)
    }

    /// Accept the highlighted row. Returns true if something was accepted.
    @discardableResult
    func acceptSelection() -> Bool {
        guard isVisible, model.titles.indices.contains(model.selectedIndex) else { return false }
        let title = model.titles[model.selectedIndex]
        hide()
        onAccept?(title)
        return true
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = true
        let host = NSHostingView(rootView: WikilinkCompletionList(model: model) { [weak self] index in
            self?.model.selectedIndex = index
            self?.acceptSelection()
        })
        panel.contentView = host
        return panel
    }
}

/// Observable list state shared between the controller and the SwiftUI view.
@MainActor
@Observable
final class WikilinkCompletionModel {
    var titles: [String] = []
    var selectedIndex: Int = 0
}

private struct WikilinkCompletionList: View {
    @Bindable var model: WikilinkCompletionModel
    let onClick: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.titles.enumerated()), id: \.offset) { index, title in
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(title)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            index == model.selectedIndex
                                ? Color.accentColor.opacity(0.25)
                                : Color.clear
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { onClick(index) }
                        .id(index)
                    }
                }
                .padding(4)
            }
            .onChange(of: model.selectedIndex) { _, new in
                withAnimation(.linear(duration: 0.08)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }
}
