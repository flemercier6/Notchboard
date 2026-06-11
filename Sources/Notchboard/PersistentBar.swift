import SwiftUI
import AppKit

/// Widgets that can sit on either side of the notch in the persistent bar.
enum WidgetKind: String, CaseIterable, Identifiable {
    case none, pomodoro, webSearch, askAI, note

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .pomodoro: return "Pomodoro"
        case .webSearch: return "Web Search"
        case .askAI: return "Ask AI"
        case .note: return "Note"
        }
    }

    /// Kinds the user can pick (everything except `.none`).
    static var selectable: [WidgetKind] { [.pomodoro, .webSearch, .askAI, .note] }

    var systemImage: String {
        switch self {
        case .none: return "minus"
        case .pomodoro: return "timer"
        case .webSearch: return "magnifyingglass"
        case .askAI: return "sparkles"
        case .note: return "note.text"
        }
    }
}

enum ShelfOpenMode: String, CaseIterable, Identifiable {
    case hover, click

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hover: return "On hover"
        case .click: return "On click"
        }
    }
}

/// Persisted choice of what sits left and right of the notch, plus the shared
/// Pomodoro timer.
/// A toggleable section in the Dash tab.
enum DashSection: String, CaseIterable, Identifiable {
    case audio, calendar, notifications
    var id: String { rawValue }
    var title: String {
        switch self {
        case .audio: return "Audio player"
        case .calendar: return "Calendar"
        case .notifications: return "Notifications"
        }
    }
}

@MainActor
final class PersistentBarSettings: ObservableObject {
    @Published var widgets: [WidgetKind] { didSet { save() } }
    @Published var openMode: ShelfOpenMode { didSet { save() } }
    /// Which Dash sections the user wants visible.
    @Published var dashSections: Set<DashSection> { didSet { saveDashSections() } }

    let pomodoro = PomodoroTimer()

    func isDashSectionOn(_ section: DashSection) -> Bool { dashSections.contains(section) }

    func toggleDashSection(_ section: DashSection) {
        if dashSections.contains(section) { dashSections.remove(section) }
        else { dashSections.insert(section) }
    }

    init() {
        let defaults = UserDefaults.standard
        let storedWidgets = defaults.stringArray(forKey: "bar.widgets")?
            .compactMap(WidgetKind.init(rawValue:))
            .filter { $0 != .none } ?? []
        if storedWidgets.isEmpty {
            let left = WidgetKind(rawValue: defaults.string(forKey: "bar.left") ?? "") ?? .none
            let right = WidgetKind(rawValue: defaults.string(forKey: "bar.right") ?? "") ?? .none
            widgets = [left, right].filter { $0 != .none }
        } else {
            widgets = Array(SetPreservingOrder(storedWidgets))
        }
        openMode = ShelfOpenMode(rawValue: defaults.string(forKey: "shelf.openMode") ?? "") ?? .hover
        if let stored = defaults.array(forKey: "dash.sections") as? [String] {
            dashSections = Set(stored.compactMap(DashSection.init(rawValue:)))
        } else {
            dashSections = Set(DashSection.allCases)   // all on by default
        }
    }

    private func saveDashSections() {
        UserDefaults.standard.set(dashSections.map(\.rawValue), forKey: "dash.sections")
    }

    func insertWidget(_ kind: WidgetKind, at index: Int) {
        guard kind != .none else { return }
        var updated = widgets.filter { $0 != kind }
        let target = min(max(index, 0), updated.count)
        updated.insert(kind, at: target)
        widgets = updated
    }

    func removeWidget(_ kind: WidgetKind) {
        widgets.removeAll { $0 == kind }
    }

    private func save() {
        UserDefaults.standard.set(widgets.map(\.rawValue), forKey: "bar.widgets")
        UserDefaults.standard.set(openMode.rawValue, forKey: "shelf.openMode")
    }
}

private struct SetPreservingOrder<Element: Hashable>: Sequence {
    private let values: [Element]

    init(_ source: [Element]) {
        var seen = Set<Element>()
        values = source.filter { seen.insert($0).inserted }
    }

    func makeIterator() -> Array<Element>.Iterator {
        values.makeIterator()
    }
}

/// A simple 25-minute Pomodoro countdown.
@MainActor
final class PomodoroTimer: ObservableObject {
    @Published private(set) var remaining = 25 * 60
    @Published private(set) var running = false

    private let duration = 25 * 60
    private var timer: Timer?

    var display: String {
        String(format: "%02d:%02d", remaining / 60, remaining % 60)
    }

    func toggle() { running ? pause() : start() }

    func start() {
        running = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.remaining > 0 {
                    self.remaining -= 1
                } else {
                    self.reset()
                }
            }
        }
    }

    func pause() {
        running = false
        timer?.invalidate()
        timer = nil
    }

    func reset() {
        pause()
        remaining = duration
    }
}

/// Always-visible widgets flanking the notch, sitting on a single continuous
/// black bar (one block, notch in the middle) shaped like a small notch:
/// concave top shoulders, convex bottom corners.
struct PersistentBar: View {
    @ObservedObject var settings: PersistentBarSettings
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    var isClickPreviewActive: Bool = false
    var isConfiguring: Bool = false
    var widgetDrag: WidgetDragState? = nil
    var onOpenNote: () -> Void = {}

    @State private var isWidgetTargeted = false
    @State private var leftWidth: CGFloat = 0
    @State private var rightWidth: CGFloat = 0

    private var leftWidgets: [WidgetKind] {
        Array(settings.widgets.prefix((settings.widgets.count + 1) / 2))
    }

    private var rightWidgets: [WidgetKind] {
        Array(settings.widgets.dropFirst(leftWidgets.count))
    }

    // Outer breathing room so the outermost widgets clear the bar's concave
    // shoulders instead of being clipped/crowded by them.
    private let outerMargin: CGFloat = 16

    // Each side = its own content width + an outer margin (responsive per widget).
    // A min width applies only to an EMPTY side while configuring (drop zone).
    private var leftSide: CGFloat { leftWidth > 0 ? leftWidth + outerMargin : (isConfiguring ? 72 : 0) }
    private var rightSide: CGFloat { rightWidth > 0 ? rightWidth + outerMargin : (isConfiguring ? 72 : 0) }

    private var barWidth: CGFloat { leftSide + notchWidth + rightSide }

    // The bar is centered by its container; shift it so the notch GAP (not the
    // bar) lines up with the physical notch even when the sides differ.
    private var notchOffset: CGFloat { (rightSide - leftSide) / 2 }

    var body: some View {
        ZStack {
            // One continuous black background spanning both widgets and the
            // notch. Purely visual (no hit testing) so the central notch hover
            // zone behind it still opens the shelf; widgets stay clickable.
            NotchShape(topCornerRadius: 10, bottomCornerRadius: 13)
                .fill(Color.black)
                .allowsHitTesting(false)

            // While configuring: dashed drop zones + a drop layer BELOW the
            // widgets, so the widgets' remove buttons stay clickable on top.
            if isConfiguring {
                configuringOverlay
            }

            HStack(spacing: 0) {
                widgetGroup(leftWidgets, isLeft: true)
                    .frame(width: leftSide, alignment: .trailing)
                Color.clear.frame(width: notchWidth)
                widgetGroup(rightWidgets, isLeft: false)
                    .frame(width: rightSide, alignment: .leading)
            }
        }
        .frame(width: barWidth, height: notchHeight)
        .preference(key: BarWidthKey.self, value: barWidth)
        // The bar's left visual edge relative to the window center (negative =
        // left). Lets the email notification emerge from the left of the bar.
        .preference(key: BarLeftEdgeKey.self, value: -barWidth / 2 + notchOffset)
        .offset(x: notchOffset)
        .scaleEffect(isClickPreviewActive ? 1.05 : 1, anchor: .top)
        .animation(.spring(response: 0.24, dampingFraction: 0.84), value: isClickPreviewActive)
        .onPreferenceChange(SideWidthKey.self) { widths in
            leftWidth = widths[true] ?? 0
            rightWidth = widths[false] ?? 0
        }
    }

    private func widgetGroup(_ widgets: [WidgetKind], isLeft: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(widgets) { kind in
                widget(kind)
                    .padding(.horizontal, 10)
                    .frame(height: notchHeight)
                    .overlay(alignment: .topTrailing) {
                        if isConfiguring {
                            Button {
                                settings.removeWidget(kind)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                                    .font(.system(size: 13))
                            }
                            .buttonStyle(.plain)
                            .padding(2)
                        }
                    }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .background(GeometryReader { geo in
            Color.clear.preference(key: SideWidthKey.self, value: [isLeft: geo.size.width])
        })
    }

    private var configuringOverlay: some View {
        HStack(spacing: 0) {
            dropZone.frame(width: leftSide)
            Color.clear.frame(width: notchWidth)
            dropZone.frame(width: rightSide)
        }
        // A near-invisible hit layer makes the whole bar a valid drop target.
        .background(
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onDrop(of: [NotchView.widgetType], isTargeted: $isWidgetTargeted) { providers, location in
                    handleWidgetDrop(providers, at: location)
                }
        )
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(
                isWidgetTargeted ? Color.accentColor : Color.white.opacity(0.3),
                style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
            )
            .padding(4)
            .allowsHitTesting(false)
    }

    private func handleWidgetDrop(_ providers: [NSItemProvider], at location: CGPoint) -> Bool {
        let atLeft = location.x < barWidth / 2
        let index = atLeft ? 0 : settings.widgets.count

        if let kind = widgetDrag?.kind {
            settings.insertWidget(kind, at: index)
            widgetDrag?.kind = nil
            return true
        }
        guard let provider = providers.first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: NotchView.widgetType.identifier) { data, _ in
            guard let data,
                  let raw = String(data: data, encoding: .utf8),
                  let kind = WidgetKind(rawValue: raw) else { return }
            Task { @MainActor in settings.insertWidget(kind, at: index) }
        }
        return true
    }

    @ViewBuilder
    private func widget(_ kind: WidgetKind) -> some View {
        switch kind {
        case .pomodoro:
            PomodoroWidget(timer: settings.pomodoro)
        case .webSearch:
            iconButton("magnifyingglass", help: "Web search") {
                if let url = URL(string: "https://www.google.com") {
                    NSWorkspace.shared.open(url)
                }
            }
        case .askAI:
            iconButton("sparkles", help: "Ask AI (coming soon)") {}
        case .note:
            iconButton("note.text", help: "Notes") { onOpenNote() }
        case .none:
            EmptyView()
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Reports the persistent bar's total width so other panels (e.g. the compact
/// search) can match it and feel like an extension of the bar.
struct BarWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Reports the bar's left visual edge (x relative to the window center; negative
/// is left) so the email notification can slide out from there.
struct BarLeftEdgeKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

/// Reports each side's content width (true = left) so the bar can reserve the
/// wider side on both sides and keep the notch centered.
private struct SideWidthKey: PreferenceKey {
    static var defaultValue: [Bool: CGFloat] = [:]
    static func reduce(value: inout [Bool: CGFloat], nextValue: () -> [Bool: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct PomodoroWidget: View {
    @ObservedObject var timer: PomodoroTimer

    var body: some View {
        Button {
            timer.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: timer.running ? "pause.fill" : "play.fill")
                    .font(.system(size: 8))
                Text(timer.display)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(.white.opacity(0.85))
        }
        .buttonStyle(.plain)
        .help("Pomodoro — click to start/pause")
    }
}
