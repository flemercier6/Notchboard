import SwiftUI

/// Drives the collapsed/expanded state from hover (the notch hot zone and the
/// panel itself) plus search. The panel stays open while either is hovered or
/// while search is active. A short delay on collapse smooths the hand-off.
@MainActor
final class NotchViewModel: ObservableObject {
    @Published private(set) var isExpanded = false

    @Published var isSearching = false
    @Published var searchText = ""
    /// True when search was opened via the global shortcut: the panel shows only
    /// the search bar until the user types something.
    @Published var searchOnly = false

    /// The color item currently being edited in place (needs keyboard focus).
    @Published var editingColorId: UUID? { didSet { recompute() } }
    /// True while the snippet editor is open (needs keyboard focus).
    @Published var isEditingSnippet = false { didSet { recompute() } }
    /// True while the widget-configuration panel is open (keeps the panel open).
    @Published var isConfiguringWidgets = false { didSet { recompute() } }
    /// True while the note editor is open (keeps the panel open + window key).
    @Published var isEditingNote = false { didSet { recompute() } }

    private var notchHover = false
    private var panelHover = false
    private var collapseTask: Task<Void, Never>?

    func setNotchHover(_ value: Bool) {
        notchHover = value
        recompute()
    }

    func setPanelHover(_ value: Bool) {
        panelHover = value
        recompute()
    }

    /// Open the search field. `compact` = opened via the global shortcut, so the
    /// panel stays minimal (just the bar) until the user types.
    func openSearch(compact: Bool) {
        searchOnly = compact
        isSearching = true
        recompute()
    }

    func closeSearch() {
        let wasCompact = searchOnly
        isSearching = false
        searchOnly = false
        searchText = ""
        if wasCompact {
            // A shortcut-opened (compact) search collapses fully on close — it
            // must not fall back to the larger hover-expanded panel.
            forceCollapse()
        } else {
            recompute()
        }
    }

    /// Fully close everything (search + panel), ignoring hover. Used when the
    /// user clicks outside the panel while searching.
    func dismiss() {
        isSearching = false
        searchOnly = false
        searchText = ""
        forceCollapse()
    }

    private func forceCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
        notchHover = false
        panelHover = false
        isExpanded = false
    }

    private func recompute() {
        let shouldExpand = notchHover || panelHover || isSearching
            || editingColorId != nil || isEditingSnippet || isConfiguringWidgets || isEditingNote
        if shouldExpand {
            collapseTask?.cancel()
            collapseTask = nil
            if !isExpanded { isExpanded = true }
        } else if isExpanded {
            collapseTask?.cancel()
            collapseTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                self?.isExpanded = false
            }
        }
    }
}
