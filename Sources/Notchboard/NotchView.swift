import SwiftUI
import UniformTypeIdentifiers

struct NotchView: View {
    @ObservedObject var store: ShelfStore
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var driveAuth: GoogleDriveAuth
    @ObservedObject var driveService: GoogleDriveService
    @ObservedObject var gmailService: GmailService
    @ObservedObject var calendarService: GoogleCalendarService
    @ObservedObject var gmailNotifier: GmailNotifier
    @ObservedObject var meeting: MeetingController
    @ObservedObject var nowPlaying: NowPlayingService
    @ObservedObject var appleCalendar: AppleCalendarService
    @ObservedObject var slack: SlackService
    @ObservedObject var notionAuth: NotionAuth
    @ObservedObject var notionService: NotionService
    @ObservedObject var supabase: SupabaseManager
    @ObservedObject var sync: SyncService
    @State private var emailBanner: IncomingEmail?
    @State private var slackBanner: SlackMessage?
    @State private var slackBannerTask: Task<Void, Never>?
    @State private var emailBannerTask: Task<Void, Never>?
    @State private var screenshotBanner: ShelfItem?
    @State private var screenshotBannerTask: Task<Void, Never>?
    @State private var showSettings = false
    @State private var settingsSection: SettingsSection = .account
    @State private var authEmail = ""
    @State private var authPassword = ""
    @State private var authIsSignUp = false
    @State private var barLeftEdge: CGFloat = 0
    @State private var meetingHoverStop = false
    @State private var selectedCalendarDay = Date()
    @State private var scrolledDayId: String?
    @State private var audioCardHeight: CGFloat = 96
    @State private var meetingTabWidthMeasured: CGFloat = 90
    @State private var nowPlayingHover = false
    @State private var isDropTargeted = false
    @State private var selection: ShelfSelection = .all
    @State private var tab: ShelfTab = .assets
    @State private var hoveredTab: ShelfTab?
    @State private var snippetDraft: SnippetDraft?
    @State private var editingNoteId: UUID?
    @State private var reorder = ReorderState()
    @State private var dropTargetId: UUID?
    @State private var dropAtEnd = false
    @State private var tileMidX: [UUID: CGFloat] = [:]
    @State private var widgetDrag = WidgetDragState()
    @State private var widgetInsertionIndex: Int?
    @State private var widgetMidX: [WidgetKind: CGFloat] = [:]
    @State private var isNotchHovering = false
    @State private var isImportPanelPresented = false
    @State private var isImportNotchTargeted = false
    @State private var isImportPanelTargeted = false
    @State private var isImportDropTargeted = false
    @State private var isImportPanelSuppressed = false
    @State private var importPanelCloseTask: Task<Void, Never>?
    @State private var importPanelSuppressTask: Task<Void, Never>?
    @State private var revealItemId: UUID?

    static let shelfSpace = "shelf"
    static let widgetBarSpace = "widgetBar"
    @StateObject private var persistentSettings = PersistentBarSettings()
    @StateObject private var slash = SlashController()
    @StateObject private var openAI = OpenAIService()
    @State private var aiMode = false

    private let metrics = NotchMetrics.current()

    private static let tileSide: CGFloat = 104
    private static let innerMargin: CGFloat = 12
    /// Width of the compact (shortcut) search panel before any results show.
    private static let compactSearchWidth: CGFloat = 360
    private static let importPanelHorizontalPadding: CGFloat = 24 + Self.innerMargin
    private static let importPanelTopPadding: CGFloat = 10
    private static let importPanelBottomPadding: CGFloat = 14
    private static let importDropZoneHeight: CGFloat = 58

    /// Internal drag type carrying an item's id, so a tile can be dropped onto a
    /// folder pill to file it. External drags (from Finder, etc.) don't carry it.
    static let itemType = UTType(exportedAs: "com.fredericlemercier.notchboard.item")
    static let widgetType = UTType(exportedAs: "com.fredericlemercier.notchboard.widget")

    private var filteredItems: [ShelfItem] {
        store.items.filter { selection.matches($0) && matchesSearch($0) }
    }

    private func matchesSearch(_ item: ShelfItem) -> Bool {
        let query = viewModel.searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        switch item.payload {
        case .text(let string): return string.localizedCaseInsensitiveContains(query)
        case .image(_, let name, _): return name.localizedCaseInsensitiveContains(query)
        case .file(_, let name): return name.localizedCaseInsensitiveContains(query)
        case .color(let hex): return hex.localizedCaseInsensitiveContains(query)
        case .snippet(let trigger, let replacement):
            return trigger.localizedCaseInsensitiveContains(query)
                || replacement.localizedCaseInsensitiveContains(query)
        case .note(let content):
            return content.localizedCaseInsensitiveContains(query)
        }
    }

    /// Opened via the global shortcut and nothing typed yet → show only the bar.
    private var isCompactSearch: Bool {
        viewModel.searchOnly && viewModel.searchText.isEmpty
    }

    private var trimmedQuery: String {
        viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// On the "All" tab with a query, search spans everything — local items plus
    /// Drive, Gmail and Calendar.
    private var isGlobalSearching: Bool {
        selection == .all && !trimmedQuery.isEmpty
    }

    /// The folder a freshly-added item should land in (when a folder is open).
    private var currentFolderId: UUID? {
        if case .folder(let id) = selection { return id }
        return nil
    }

    private var isClickPreviewActive: Bool {
        persistentSettings.openMode == .click
            && isNotchHovering
            && !viewModel.isExpanded
            && !isImportPanelPresented
    }

    /// The selectable types currently present among the items.
    private var presentTypes: [ShelfSelection] {
        [(ShelfPayload.Kind.text, ShelfSelection.text),
         (.image, .images),
         (.file, .files),
         (.color, .colors),
         (.snippet, .snippets),
         (.note, .notes)]
            .filter { kind, _ in store.items.contains { $0.payload.kind == kind } }
            .map { $0.1 }
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Hover/drop hot zone for the notch — the only thing on screen when
            // collapsed. It MUST sit BEHIND the shelf: it's centered and a bit
            // taller than the notch, so if it were in front its contentShape
            // would swallow clicks on the pills sitting under the notch.
            //
            // NOTE: a fully-transparent Color.clear is NOT a valid onDrop target
            // (SwiftUI quirk: drop hit-testing needs real pixels, unlike onHover
            // which uses tracking areas). So we give it a near-invisible fill.
            Color.black.opacity(0.001)
                .frame(
                    width: max(metrics.notchWidth - 28, 40),
                    height: max(metrics.notchHeight - 8, 16)
                )
                .contentShape(Rectangle())
                .onHover { updateNotchHover($0) }
                .onTapGesture {
                    if persistentSettings.openMode == .click {
                        viewModel.setPanelHover(true)
                    }
                }
                // Spring-load: dragging external content onto the notch opens a
                // compact import panel. onHover doesn't fire during a drag, so
                // we rely on the drop target's targeting instead.
                .onDrop(of: importDropTypes, isTargeted: Binding(
                    get: { isImportNotchTargeted },
                    set: { targeted in
                        isImportNotchTargeted = targeted
                        if targeted {
                            presentImportPanel()
                        } else {
                            scheduleImportPanelClose(after: 2_000_000_000)
                        }
                    }
                )) { providers in
                    performImportDrop(providers)
                }

            if isImportPanelPresented {
                importPanel
                    .transition(.scale(scale: 0.55, anchor: .top).combined(with: .opacity))
            } else if viewModel.isExpanded {
                // The shelf (in front when expanded). Its hover keeps it open and,
                // being in front, its pills receive clicks.
                shelf
                    .onHover { viewModel.setPanelHover($0) }
                    // Grows out of the notch: scale anchored at the top-center
                    // (where the notch is) so it appears to unfold downward and
                    // outward, with a slight spring overshoot.
                    .transition(.scale(scale: 0.55, anchor: .top).combined(with: .opacity))
            }

            // New-email notification — slides out from the left of the bar, sitting
            // in the notch band. Placed BEFORE the bar so the bar draws on top and
            // hides the edge that tucks under the notch.
            if let emailBanner {
                emailBannerView(emailBanner)
                    .id(emailBanner.id)
                    .offset(x: emailBannerOffsetX)
                    .transition(.notchReveal)
            }

            // New Slack message notification (same left slot).
            if let slackBanner, emailBanner == nil {
                slackBannerView(slackBanner)
                    .id(slackBanner.id)
                    .offset(x: slackBannerOffsetX)
                    .transition(.notchReveal)
            }

            // Screenshot auto-saved confirmation (same left slot).
            if let screenshotBanner, emailBanner == nil, slackBanner == nil {
                screenshotBannerView(screenshotBanner)
                    .id(screenshotBanner.id)
                    .offset(x: slackBannerOffsetX)
                    .transition(.notchReveal)
            }

            // Persistent compact bar — always-visible widgets flanking the notch.
            PersistentBar(
                settings: persistentSettings,
                notchWidth: metrics.notchWidth,
                notchHeight: metrics.notchHeight,
                isClickPreviewActive: isClickPreviewActive,
                isConfiguring: viewModel.isConfiguringWidgets,
                widgetDrag: widgetDrag,
                onOpenNote: { openNewNote() }
            )

            // Compact now-playing: just the artwork left of the notch (collapsed
            // only; the full card shows in the expanded shelf). Hidden while a
            // meeting tab or email banner occupies the left slot.
            if let track = nowPlaying.track, !viewModel.isExpanded,
               meeting.state == .idle, emailBanner == nil, slackBanner == nil, screenshotBanner == nil {
                nowPlayingCompactTab(track)
                    .offset(x: nowPlayingOffsetX)
                    .transition(.notchReveal)
                    .zIndex(14)
            }

            if meeting.state != .idle {
                meetingTabView
                    .offset(x: meetingTabOffsetX)
                    .transition(.notchReveal)
                    .zIndex(15)
            }

            if showSettings {
                settingsOverlay
                    .zIndex(50)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: showSettings)
        .onChange(of: showSettings) { _, open in viewModel.isSettingsOpen = open }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: nowPlaying.track != nil)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: meeting.state)
        .animation(.spring(response: 0.34, dampingFraction: 0.72), value: viewModel.isExpanded)
        .animation(.spring(response: 0.34, dampingFraction: 0.72), value: isImportPanelPresented)
        .onChange(of: persistentSettings.openMode) {
            updateNotchHover(isNotchHovering)
        }
        .onChange(of: gmailNotifier.incoming) { _, email in
            if let email { showEmailBanner(email) }
        }
        .onChange(of: slack.incoming) { _, message in
            if let message { showSlackBanner(message) }
        }
        .onChange(of: store.lastScreenshotAdded) { _, item in
            if let item { showScreenshotBanner(item) }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: slackBanner)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: screenshotBanner)
        .onPreferenceChange(BarLeftEdgeKey.self) { barLeftEdge = $0 }
    }

    private var notchShape: NotchShape {
        NotchShape(topCornerRadius: 24, bottomCornerRadius: 32)
    }

    /// Frosted backdrop (behind-window blur) + a radial gradient that fades from
    /// solid black at the notch to 30% black at the edges.
    private var shelfBackground: some View {
        GeometryReader { geo in
            // Origin at the notch: horizontally centered, vertically in the notch band.
            let centerY = (metrics.notchHeight * 0.5) / max(geo.size.height, 1)
            ZStack {
                VisualEffectBlur()
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color.black, location: 0.15),
                        .init(color: Color.black.opacity(0.2), location: 1.0),
                    ]),
                    center: UnitPoint(x: 0.5, y: centerY),
                    startRadius: 0,
                    endRadius: hypot(geo.size.width, geo.size.height)
                )
            }
        }
    }

    private var shelfContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.isConfiguringWidgets {
                widgetConfigurator
            } else {
                searchRow

                // Spotlight-style answer mode takes over the body.
                if aiMode {
                    aiAnswerView
                } else if !isCompactSearch {
                    // Web + Ask-AI shortcuts whenever there's a query.
                    if viewModel.isSearching && !trimmedQuery.isEmpty {
                        searchActions
                    }
                    if snippetDraft != nil {
                        snippetEditor
                    } else if editingNoteId != nil {
                        noteEditorView
                    } else if isGlobalSearching {
                        globalSearchContent
                    } else {
                        tabBar
                        tabContent
                    }
                } else {
                    EmptyView()
                }
            }
        }
        // Push content below the physical camera notch; the black background
        // still reaches all the way up to the screen top (top: 0).
        .padding(.top, metrics.notchHeight)
        // Uniform inner margin between the tiles and the visible panel edges.
        // The left/right edges of the panel body sit at the concave radius (24),
        // so horizontal padding is that radius plus the same margin used at the
        // bottom — giving an equal gap on the sides and underneath.
        .padding(.horizontal, 24 + Self.innerMargin)
        .padding(.bottom, Self.innerMargin)
        // Compact search uses a fixed width; the Dash hugs its sections; every
        // other tab fills the available width. An EXPLICIT width (not maxWidth) is
        // required for the Dash — otherwise the tab bar's intrinsic width acts as
        // a floor and the shelf never visibly shrinks.
        .modifier(ShelfWidthModifier(width: shelfFixedWidth))
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: shelfFixedWidth)
    }

    /// Floor that keeps the tab bar (Dash/Assets/Notes/Snippets/Colors + add)
    /// readable — wide enough for all five pills plus the add menu.
    private static let tabBarFloorWidth: CGFloat = 560

    /// The widest the shelf can be — matches the host panel's width
    /// (NotchWindow.minExpandedWidth). The Dash may grow up to this so every
    /// section stays visible; other tabs keep their natural 45% footprint.
    private var availableShelfWidth: CGFloat {
        min(metrics.screenFrame.width, max(metrics.screenFrame.width * 0.45, 980))
    }

    /// The Dash's width, driven by its visible sections. This is the single width
    /// used by EVERY tab (so the shelf footprint is uniform): the more Dash
    /// sections are enabled, the wider the whole shelf — on all tabs.
    private var dashShelfWidth: CGFloat {
        let sections = visibleDashSections
        let sectionsWidth = sections.reduce(0) { $0 + dashSectionWidth($1) }
            + CGFloat(max(0, sections.count - 1)) * Self.dashSectionGap
        let horizontalPadding: CGFloat = 2 * (24 + Self.innerMargin)
        let content = max(sectionsWidth, Self.tabBarFloorWidth) + horizontalPadding
        return min(content, availableShelfWidth - 48)
    }

    /// Explicit shelf width. Compact search is fixed; every other state uses the
    /// Dash width so all tabs share the same footprint.
    private var shelfFixedWidth: CGFloat? {
        if isCompactSearch { return 500 }
        return dashShelfWidth
    }

    // MARK: - Expanded shelf tabs

    private var tabBar: some View {
        HStack(spacing: 10) {
            ForEach(ShelfTab.allCases) { t in
                tabPill(t)
            }
            Spacer(minLength: 8)
            addMenu
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 12)
    }

    private func tabPill(_ t: ShelfTab) -> some View {
        let active = tab == t
        let hovered = hoveredTab == t
        // Inactive pills brighten toward white on hover; active stays white.
        let color: Color = active
            ? .white
            : (hovered ? (Color(hex: "#CCCCCC") ?? .white) : (Color(hex: "#888888") ?? .gray))
        return Button { tab = t } label: {
            HStack(spacing: 5) {
                if let icon = TabIcons.icon(t) {
                    Image(nsImage: icon)
                        .renderingMode(.template)
                        .resizable().scaledToFit()
                        .frame(width: 11, height: 11)
                }
                Text(t.title)
                    .font(.system(size: 12, weight: active ? .semibold : .medium))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(FrostedBackground(cornerRadius: 50))
            // A brighter wash + subtle lift on hover for inactive pills.
            .overlay {
                if hovered && !active {
                    RoundedRectangle(cornerRadius: 50, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 50, style: .continuous))
            .scaleEffect(hovered && !active ? 1.05 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hoveredTab = $0 ? t : (hoveredTab == t ? nil : hoveredTab) }
        .animation(.easeOut(duration: 0.15), value: hovered)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .dash: dashContent
        case .assets: assetsContent
        case .notes: notesContent
        case .snippets: snippetsContent
        case .colors: colorsContent
        }
    }

    // --- Dash ---

    private var calendarConnected: Bool {
        driveAuth.isConnected && driveAuth.hasScope(GoogleScopes.calendar)
    }

    /// Show the calendar if Google Calendar is connected or Apple Calendar has events.
    private var showCalendar: Bool {
        calendarConnected || !appleCalendar.events.isEmpty
    }

    // Per-section min widths — guarantee each section stays readable. The shelf
    // width adapts to the sum of the visible sections (see `shelfMaxWidth`).
    private static let dashSectionGap: CGFloat = 16
    private func dashSectionWidth(_ section: DashSection) -> CGFloat {
        switch section {
        case .audio: return 250
        case .calendar: return 280
        case .notifications: return 280
        }
    }

    /// Dash sections that are both enabled in settings AND have content to show.
    private var visibleDashSections: [DashSection] {
        DashSection.allCases.filter { section in
            guard persistentSettings.isDashSectionOn(section) else { return false }
            switch section {
            case .audio: return nowPlaying.track != nil
            case .calendar: return showCalendar
            case .notifications: return true
            }
        }
    }

    @ViewBuilder
    private var dashContent: some View {
        let sections = visibleDashSections
        HStack(alignment: .top, spacing: Self.dashSectionGap) {
            if sections.isEmpty {
                Text("Enable a section in settings (⚙).")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
            } else {
                ForEach(sections) { section in
                    dashSectionView(section).frame(width: dashSectionWidth(section))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onPreferenceChange(AudioCardHeightKey.self) { audioCardHeight = $0 }
    }

    @ViewBuilder
    private func dashSectionView(_ section: DashSection) -> some View {
        switch section {
        case .audio:
            if let track = nowPlaying.track { mediaCard(track) }
        case .calendar:
            calendarSection
        case .notifications:
            notificationsSection
        }
    }

    // --- Dash: notifications ---

    /// Gmail + Slack notifications merged, newest first.
    private var mergedNotifications: [AppNotification] {
        (gmailNotifier.feed + slack.feed).sorted { $0.date > $1.date }
    }

    /// Fixed-height scrollable list — never changes the shelf height. Fills the
    /// audio card's height when music plays; otherwise shows up to 3 rows.
    private var notificationsListHeight: CGFloat {
        let rowHeight: CGFloat = 30
        if visibleDashSections.contains(.audio) {
            return max(2 * rowHeight, audioCardHeight - 30)   // minus the title label
        }
        let count = max(1, min(mergedNotifications.count, 3))
        return CGFloat(count) * rowHeight
    }

    private var notificationsSection: some View {
        let notes = mergedNotifications
        return VStack(alignment: .leading, spacing: 10) {
            Text("Notifications")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            ScrollView(.vertical, showsIndicators: false) {
                if notes.isEmpty {
                    Text("No notifications")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(notes) { notificationRow($0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: notificationsListHeight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func notificationRow(_ note: AppNotification) -> some View {
        HStack(spacing: 8) {
            notificationLogo(note.source)
                .frame(width: 16, height: 16)
            Text(note.source.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
            if let avatar = note.avatarURL {
                AsyncImage(url: avatar) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Circle().fill(Color.white.opacity(0.12))
                }
                .frame(width: 16, height: 16)
                .clipShape(Circle())
            }
            Text(note.sender)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .layoutPriority(1)
            Text(note.preview)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func notificationLogo(_ source: NotificationSource) -> some View {
        switch source {
        case .gmail:
            if let logo = GoogleAssets.gmail {
                Image(nsImage: logo).resizable().scaledToFit()
            } else {
                Image(systemName: "envelope.fill").resizable().scaledToFit()
                    .foregroundStyle(.white.opacity(0.8))
            }
        case .slack:
            if let logo = SlackAssets.logo {
                Image(nsImage: logo).resizable().scaledToFit()
            } else {
                Image(systemName: "message.fill").resizable().scaledToFit()
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    /// Events list height: when music plays it fills the audio card's height
    /// (so the card defines the shelf height, not the calendar); otherwise it
    /// shows up to 3 events and scrolls the rest.
    private var eventsListHeight: CGFloat {
        let rowHeight: CGFloat = 23
        if visibleDashSections.contains(.audio) {
            // Fill the card minus the day strip/header above the list (~54).
            return max(2 * rowHeight, audioCardHeight - 54)
        }
        let count = max(1, min(eventsOn(selectedCalendarDay).count, 3))
        return CGFloat(count) * rowHeight
    }

    // --- Dash: calendar ---

    private var calendarSection: some View {
        // Computed once per render (not per day) — O(1) lookups in the strip.
        let eventDays = daysWithEvents
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                Text(monthLabel)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(calendarDays, id: \.self) { day in
                            dayColumn(day, hasEvents: eventDays.contains(dayId(day))).id(dayId(day))
                        }
                    }
                    .scrollTargetLayout()
                    .frame(height: 48)
                }
                .frame(height: 48)
                // Anchor the tracked day to the LEADING edge — without this the
                // programmatic scroll-to-today overshoots and clips today in half.
                .scrollPosition(id: $scrolledDayId, anchor: .leading)
                .onAppear {
                    if scrolledDayId == nil {
                        scrolledDayId = dayId(Calendar.current.startOfDay(for: Date()))
                    }
                }
            }
            // Fixed-height, vertically scrollable list — doesn't change the
            // shelf height regardless of how many events the day has.
            let dayEvents = eventsOn(selectedCalendarDay)
            ScrollView(.vertical, showsIndicators: false) {
                if dayEvents.isEmpty {
                    Text("No events")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(dayEvents) { event in
                            HStack(spacing: 7) {
                                Text(event.summary)
                                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                                Circle()
                                    .fill(Color(hex: event.colorHex ?? "") ?? Color.accentColor)
                                    .frame(width: 7, height: 7)
                                Spacer(minLength: 8)
                                Text(event.timeRange)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.6))
                                    .monospacedDigit()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: eventsListHeight)
            // Fade the bottom edge so scrolled content melts away instead of
            // hitting a hard cut-off line.
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0.0),
                        .init(color: .black, location: 0.80),
                        .init(color: .clear, location: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dayColumn(_ day: Date, hasEvents: Bool) -> some View {
        let cal = Calendar.current
        let isSelected = cal.isDate(day, inSameDayAs: selectedCalendarDay)
        let isToday = cal.isDateInToday(day)
        return Button { selectedCalendarDay = day } label: {
            VStack(spacing: 3) {
                Text(weekdayLetter(day))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(isSelected ? 0.9 : 0.4))
                ZStack {
                    if isSelected {
                        Circle().fill(Color.accentColor).frame(width: 24, height: 24)
                    }
                    Text(dayNumber(day))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : (isToday ? Color.orange : .white))
                }
                .frame(width: 24, height: 24)
                Circle()
                    .fill(hasEvents ? (isSelected ? Color.accentColor : Color.white.opacity(0.4)) : .clear)
                    .frame(width: 4, height: 4)
            }
            .frame(width: 26)
        }
        .buttonStyle(.plain)
    }

    private var calendarDays: [Date] {
        let cal = Calendar.current
        let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))
            ?? cal.startOfDay(for: Date())
        // ~4 weeks before, ~20 after — scroll freely across months.
        let start = cal.date(byAdding: .day, value: -28, to: weekStart) ?? weekStart
        return (0..<168).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    // Cached formatters — building a DateFormatter is very expensive, and these
    // run for all 168 day columns on every recomposition. Creating them per call
    // made the calendar scroll stutter.
    private static let dayIdFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "LLLL"
        return f
    }()
    private static let weekdaySymbols: [String] = {
        let f = DateFormatter()
        f.locale = Locale.current
        return (f.veryShortWeekdaySymbols ?? ["S", "M", "T", "W", "T", "F", "S"]).map { $0.uppercased() }
    }()

    private func dayId(_ day: Date) -> String {
        Self.dayIdFormatter.string(from: day)
    }

    /// Google + Apple events merged, with cross-source duplicates removed. A
    /// Google account synced into macOS Calendar shows up in BOTH feeds; since the
    /// two sources use different ids, we de-dupe by content (title + start + end).
    private var combinedEvents: [CalendarEvent] {
        var seen = Set<String>()
        var result: [CalendarEvent] = []
        for event in calendarService.events + appleCalendar.events {
            let key = """
            \(event.summary.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())\
            |\(event.start?.timeIntervalSinceReferenceDate ?? 0)\
            |\(event.end?.timeIntervalSinceReferenceDate ?? 0)
            """
            if seen.insert(key).inserted { result.append(event) }
        }
        return result
    }

    /// Day-ids (yyyy-MM-dd) that have at least one event — O(1) lookup per day.
    private var daysWithEvents: Set<String> {
        var set = Set<String>()
        for event in combinedEvents {
            if let start = event.start { set.insert(dayId(start)) }
        }
        return set
    }

    private func eventsOn(_ day: Date) -> [CalendarEvent] {
        combinedEvents
            .filter { event in
                guard let start = event.start else { return false }
                return Calendar.current.isDate(start, inSameDayAs: day)
            }
            .sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
    }

    /// The date whose month the header shows — follows the scroll position.
    private var displayedMonthDate: Date {
        if let id = scrolledDayId, let d = Self.dayIdFormatter.date(from: id) {
            return d
        }
        return selectedCalendarDay
    }

    private var monthLabel: String {
        Self.monthFormatter.string(from: displayedMonthDate)
    }

    private func weekdayLetter(_ day: Date) -> String {
        let index = Calendar.current.component(.weekday, from: day) - 1
        return Self.weekdaySymbols[index]
    }

    private func dayNumber(_ day: Date) -> String {
        String(format: "%02d", Calendar.current.component(.day, from: day))
    }

    // --- Assets (stacked rows) ---

    private var assetsContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(localAssetKinds, id: \.self) { kind in
                    assetRow(label: kindLabel(kind)) {
                        ForEach(assetItems(kind)) { shelfItemTile($0) }
                    }
                }
                ForEach(store.folders) { folder in
                    assetRow(label: folder.name, systemIcon: "folder") {
                        let items = folderItems(folder.id)
                        if items.isEmpty {
                            Text("Empty").font(.system(size: 11)).foregroundStyle(.white.opacity(0.3))
                                .frame(height: Self.tileSide)
                        } else {
                            ForEach(items) { shelfItemTile($0) }
                        }
                    }
                }
                if showDriveRow {
                    assetRow(label: "Drive", logo: GoogleAssets.drive) { ForEach(driveService.files) { driveTile($0) } }
                }
                // Mail and Calendar are intentionally NOT shown here: Calendar lives
                // in the Dash, and email isn't shelf content.
                if assetRowCount == 0 {
                    Text("Drag content onto the notch, or connect an account in Settings.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
                }
            }
            .padding(.bottom, 2)
        }
        .frame(height: assetsHeight)
    }

    private func assetRow<C: View>(
        label: String,
        logo: NSImage? = nil,
        systemIcon: String? = nil,
        @ViewBuilder content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if let logo {
                    Image(nsImage: logo).resizable().scaledToFit().frame(width: 12, height: 12)
                } else if let systemIcon {
                    Image(systemName: systemIcon).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                }
                Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) { content() }
            }
            .frame(height: Self.tileSide)
        }
    }

    private var localAssetKinds: [ShelfPayload.Kind] {
        // Notes now live in their own tab, not in Assets.
        [.text, .image, .file].filter { kind in
            store.items.contains { $0.payload.kind == kind && $0.folderId == nil }
        }
    }

    private func assetItems(_ kind: ShelfPayload.Kind) -> [ShelfItem] {
        store.items.filter { $0.payload.kind == kind && $0.folderId == nil }
    }

    private func folderItems(_ id: UUID) -> [ShelfItem] {
        store.items.filter { $0.folderId == id }
    }

    private func kindLabel(_ kind: ShelfPayload.Kind) -> String {
        switch kind {
        case .text: return "Text"
        case .image: return "Images"
        case .file: return "Files"
        case .note: return "Notes"
        case .color: return "Colors"
        case .snippet: return "Snippets"
        }
    }

    private var showDriveRow: Bool {
        driveAuth.isConnected && driveAuth.hasScope(GoogleScopes.drive) && !driveService.files.isEmpty
    }

    private var assetRowCount: Int {
        localAssetKinds.count + store.folders.count + (showDriveRow ? 1 : 0)
    }

    private var assetsHeight: CGFloat {
        let rows = min(max(assetRowCount, 1), 3)
        let rowHeight = Self.tileSide + 22   // tile + label + spacing
        return CGFloat(rows) * rowHeight + CGFloat(rows - 1) * 14
    }

    private func loadAssetsRemotes() {
        // Only Drive is shown in Assets now (Mail/Calendar moved out).
        if driveAuth.isConnected, driveAuth.hasScope(GoogleScopes.drive), driveService.files.isEmpty {
            driveService.loadRecent()
        }
    }

    // --- Notes / Snippets / Colors ---

    private var notesContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                // Local notes (own row).
                assetRow(label: "Notes", systemIcon: "note.text") {
                    ForEach(store.items.filter { $0.payload.kind == .note }) { shelfItemTile($0) }
                    addTile { openNewNote() }
                }
                // Notion pages/databases (separate row).
                if notionAuth.isConnected {
                    assetRow(label: "Notion", logo: NotionAssets.logo) {
                        if notionService.pages.isEmpty {
                            Text(notionService.isLoading ? "Loading…" : "No shared pages")
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                                .frame(height: Self.tileSide)
                        } else {
                            ForEach(notionService.pages) { notionTile($0) }
                        }
                    }
                } else if notionAuth.isConfigured {
                    assetRow(label: "Notion", logo: NotionAssets.logo) {
                        notionConnectTile
                    }
                }
            }
            .padding(.bottom, 2)
        }
        .frame(height: notesHeight)
        .onAppear { loadNotionIfNeeded() }
    }

    private var notesRowCount: Int {
        // Local notes row is always present; the Notion row shows when connected
        // or connectable.
        1 + ((notionAuth.isConnected || notionAuth.isConfigured) ? 1 : 0)
    }

    private var notesHeight: CGFloat {
        let rows = min(max(notesRowCount, 1), 3)
        let rowHeight = Self.tileSide + 22   // tile + label + spacing
        return CGFloat(rows) * rowHeight + CGFloat(rows - 1) * 14
    }

    private func notionTile(_ page: NotionPage) -> some View {
        remoteTile(action: { notionService.open(page) }, help: page.title) {
            VStack(spacing: 8) {
                notionLogoSmall.frame(width: 26, height: 26)
                Text(page.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var notionConnectTile: some View {
        remoteTile(action: { connectNotion() }, help: "Connect Notion") {
            VStack(spacing: 8) {
                notionLogoSmall.frame(width: 24, height: 24)
                Text(notionAuth.isConnecting ? "Connecting…" : "Connect Notion")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var notionLogoSmall: some View {
        Group {
            if let logo = NotionAssets.logo {
                Image(nsImage: logo).resizable().scaledToFit()
            } else {
                Image(systemName: "doc.text").resizable().scaledToFit()
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    private func connectNotion() {
        Task {
            await notionAuth.connect()
            if notionAuth.isConnected {
                viewModel.setPanelHover(true)
                notionService.loadPages()
            }
        }
    }

    private func loadNotionIfNeeded() {
        if notionAuth.isConnected, notionService.pages.isEmpty { notionService.loadPages() }
    }

    private var snippetsContent: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(store.items.filter { $0.payload.kind == .snippet }) { shelfItemTile($0) }
                addTile {
                    snippetDraft = SnippetDraft()
                    viewModel.isEditingSnippet = true
                }
            }
        }
        .frame(height: Self.tileSide)
    }

    private var colorsContent: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(store.items.filter { $0.payload.kind == .color }) { shelfItemTile($0) }
                addTile {
                    let id = store.addColorPlaceholder(folderId: nil)
                    viewModel.editingColorId = id
                }
            }
        }
        .frame(height: Self.tileSide)
    }

    private func shelfItemTile(_ item: ShelfItem) -> some View {
        ShelfItemView(item: item, store: store, viewModel: viewModel, reorder: reorder) {
            handleItemEdit(item)
        }
    }

    private var panelBorder: some View {
        notchShape.stroke(
            isDropTargeted ? Color.accentColor : Color.white.opacity(0.08),
            lineWidth: isDropTargeted ? 2 : 1
        )
    }

    private var shelf: some View {
        shelfContent
            .background(shelfBackground)
            .clipShape(notchShape)
            // Settings pinned top-right, vertically aligned with the notch band.
            .overlay(alignment: .top) {
                HStack {
                    Spacer()
                    settingsMenu
                }
                .frame(height: metrics.notchHeight)
                .padding(.horizontal, 24 + Self.innerMargin)
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isCompactSearch)
            .onChange(of: viewModel.searchOnly) {
                if viewModel.searchOnly { selection = .all }
            }
            .onChange(of: viewModel.searchText) {
                remoteSearchIfNeeded()
                // Editing the query returns from an AI answer to live results.
                if aiMode { exitAI() }
            }
            .onChange(of: selection) { remoteSearchIfNeeded() }
            .onChange(of: viewModel.isSearching) {
                if !viewModel.isSearching { exitAI() }
            }
            .onChange(of: tab) {
                if tab == .assets { loadAssetsRemotes() }
                if tab == .dash {
                    if calendarConnected, calendarService.events.isEmpty { calendarService.loadUpcoming() }
                    appleCalendar.reload()
                }
            }
            .onChange(of: viewModel.isExpanded) {
                guard viewModel.isExpanded else { return }
                if tab == .assets { loadAssetsRemotes() }
                if tab == .dash {
                    if calendarConnected, calendarService.events.isEmpty { calendarService.loadUpcoming() }
                    appleCalendar.reload()
                }
            }
            .onChange(of: store.items.count) { resetSelectionIfNeeded() }
            .onChange(of: store.folders.count) { resetSelectionIfNeeded() }
            // Single drop target for the whole panel: reorders internal tile
            // drags (by cursor x) and adds external content.
            .coordinateSpace(name: Self.shelfSpace)
            .onDrop(of: shelfDropTypes, delegate: ShelfDropDelegate(
                store: store,
                reorder: reorder,
                orderedIds: filteredItems.map(\.id),
                tileMidX: tileMidX,
                dropTargetId: $dropTargetId,
                dropAtEnd: $dropAtEnd,
                isDropTargeted: $isDropTargeted,
                onPanelHover: { viewModel.setPanelHover($0) },
                onExternalDrop: { handleDrop($0) }
            ))
    }

    private var importPanelWidth: CGFloat {
        max(Self.compactSearchWidth + Self.importPanelHorizontalPadding * 2, metrics.notchWidth + 160)
    }

    private var importPanelInnerWidth: CGFloat {
        max(0, importPanelWidth - Self.importPanelHorizontalPadding * 2)
    }

    private var importDropZoneRect: CGRect {
        CGRect(
            x: Self.importPanelHorizontalPadding,
            y: metrics.notchHeight + Self.importPanelTopPadding,
            width: importPanelInnerWidth,
            height: Self.importDropZoneHeight
        )
    }

    private var importPanelHeight: CGFloat {
        metrics.notchHeight
            + Self.importPanelTopPadding
            + Self.importDropZoneHeight
            + Self.importPanelBottomPadding
    }

    private var importPanel: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
                .frame(height: metrics.notchHeight + Self.importPanelTopPadding)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                    .frame(width: Self.importPanelHorizontalPadding)
                importDropZone
                    .frame(width: importPanelInnerWidth)
                Spacer(minLength: 0)
                    .frame(width: Self.importPanelHorizontalPadding)
            }
            Spacer(minLength: 0)
                .frame(height: Self.importPanelBottomPadding)
        }
        .frame(width: importPanelWidth, height: importPanelHeight, alignment: .top)
        .background(notchShape.fill(Color.black))
        .overlay(
            notchShape.stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(notchShape)
        .contentShape(notchShape)
        .onDrop(of: importDropTypes, delegate: ImportPanelDropDelegate(
            dropZoneRect: importDropZoneRect,
            isPanelTargeted: $isImportPanelTargeted,
            isDropZoneTargeted: $isImportDropTargeted,
            onPresent: { presentImportPanel() },
            onScheduleClose: { scheduleImportPanelClose() },
            onPerformDrop: { performImportDrop($0) }
        ))
    }

    private var importDropZone: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(isImportDropTargeted ? Color.accentColor.opacity(0.18) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(isImportDropTargeted ? 0.44 : 0.28),
                        style: StrokeStyle(lineWidth: 1.5, dash: [9, 6])
                    )
                    .allowsHitTesting(false)
            )
            .overlay(
                Text("Import")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isImportDropTargeted ? Color.white : Color.white.opacity(0.62))
                    .allowsHitTesting(false)
            )
            .frame(height: Self.importDropZoneHeight)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var widgetConfigurator: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Widgets")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                Button {
                    viewModel.isConfiguringWidgets = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white.opacity(0.72), .black.opacity(0.35))
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .help("Close")
            }

            Text("Drag a widget onto either side of the notch")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(WidgetKind.selectable) { kind in
                        widgetPaletteTile(kind)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func widgetPaletteTile(_ kind: WidgetKind) -> some View {
        HStack(spacing: 6) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 11, weight: .semibold))
            Text(kind.title)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.82))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .onDrag {
            widgetDrag.kind = kind
            return widgetDragProvider(for: kind)
        }
        .help(kind.title)
    }

    private var widgetBarEditor: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(0.18),
                        style: StrokeStyle(lineWidth: 1, dash: [6, 5])
                    )
            )
            .overlay {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(persistentSettings.widgets.enumerated()), id: \.element) { index, kind in
                            if widgetInsertionIndex == index {
                                widgetInsertionBar
                            }
                            configuredWidgetTile(kind)
                                .background(GeometryReader { geo in
                                    Color.clear.preference(
                                        key: WidgetMidXKey.self,
                                        value: [kind: geo.frame(in: .named(Self.widgetBarSpace)).midX]
                                    )
                                })
                        }
                        if widgetInsertionIndex == persistentSettings.widgets.count {
                            widgetInsertionBar
                        }
                        if persistentSettings.widgets.isEmpty {
                            Text("Drop widgets here")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.42))
                                .padding(.horizontal, 4)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 52, alignment: .center)
                }
                .coordinateSpace(name: Self.widgetBarSpace)
                .onPreferenceChange(WidgetMidXKey.self) { widgetMidX = $0 }
            }
            .frame(height: 64)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onDrop(of: widgetDropTypes, delegate: WidgetBarDropDelegate(
                settings: persistentSettings,
                widgets: persistentSettings.widgets,
                tileMidX: widgetMidX,
                dragState: widgetDrag,
                insertionIndex: $widgetInsertionIndex
            ))
    }

    private func configuredWidgetTile(_ kind: WidgetKind) -> some View {
        HStack(spacing: 7) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 11, weight: .semibold))
            Text(kind.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Button {
                persistentSettings.removeWidget(kind)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white.opacity(0.86))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.12))
        )
        .onDrag {
            widgetDrag.kind = kind
            return widgetDragProvider(for: kind)
        }
    }

    private var widgetInsertionBar: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.accentColor)
            .frame(width: 3, height: 42)
            .transition(.opacity)
    }

    // Top bar: the pills zone takes all available width and scrolls horizontally
    // when there are too many; "+" and paste stay fixed.
    private var topBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                filterPills.padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 28)

            addMenu
        }
    }

    private var tilesScroll: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(filteredItems) { item in
                        if dropTargetId == item.id {
                            insertionBar
                        }
                        ShelfItemView(item: item, store: store, viewModel: viewModel, reorder: reorder) {
                            if case .snippet(let trigger, let replacement) = item.payload {
                                snippetDraft = SnippetDraft(id: item.id, trigger: trigger, replacement: replacement)
                                viewModel.isEditingSnippet = true
                            } else if case .note = item.payload {
                                openNote(item.id)
                            }
                        }
                        .id(item.id)
                        .background(GeometryReader { geo in
                            Color.clear.preference(
                                key: TileMidXKey.self,
                                value: [item.id: geo.frame(in: .named(NotchView.shelfSpace)).midX]
                            )
                        })
                    }

                    if dropAtEnd {
                        insertionBar
                    }

                    // One-click "add" tile when viewing colors or snippets.
                    if selection == .colors {
                        addTile {
                            let id = store.addColorPlaceholder(folderId: currentFolderId)
                            viewModel.editingColorId = id
                        }
                    } else if selection == .snippets {
                        addTile {
                            snippetDraft = SnippetDraft()
                            viewModel.isEditingSnippet = true
                        }
                    } else if filteredItems.isEmpty {
                        emptyHint
                    }
                }
                .animation(.snappy(duration: 0.2), value: filteredItems.map(\.id))
                .animation(.snappy(duration: 0.15), value: dropTargetId)
                .animation(.snappy(duration: 0.15), value: dropAtEnd)
            }
            .onPreferenceChange(TileMidXKey.self) { tileMidX = $0 }
            .onChange(of: revealItemId) {
                scrollToRevealedItem(using: proxy)
            }
        }
        // Match the tile height exactly so there's no extra vertical slack below.
        .frame(height: Self.tileSide)
    }

    private func scrollToRevealedItem(using proxy: ScrollViewProxy) {
        guard let id = revealItemId else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            withAnimation(.snappy(duration: 0.22)) {
                proxy.scrollTo(id, anchor: .center)
            }
            revealItemId = nil
        }
    }

    private var insertionBar: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.accentColor)
            .frame(width: 3, height: Self.tileSide)
            .transition(.opacity)
    }

    private func addTile(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(0.25),
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                )
                .frame(width: 130, height: Self.tileSide)
                .overlay(
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Google (Drive / Gmail / Calendar)

    // --- Drive ---

    @ViewBuilder
    private var driveContent: some View {
        if !driveAuth.isConnected {
            connectPrompt(logo: GoogleAssets.drive, fallbackSymbol: "externaldrive.fill", title: "Connect your Google Drive")
        } else {
            remoteScroll(isLoading: driveService.isLoading, isEmpty: driveService.files.isEmpty,
                         error: driveService.errorMessage) {
                ForEach(driveService.files) { file in
                    driveTile(file)
                }
            }
        }
    }

    private func driveTile(_ file: DriveFile) -> some View {
        remoteTile(action: { open(file.webViewLink) }, help: file.name) {
            VStack(spacing: 8) {
                driveIcon(file).frame(width: 40, height: 40)
                Text(file.name)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func driveIcon(_ file: DriveFile) -> some View {
        if let logo = GoogleAssets.fileLogo(for: file.mimeType) {
            Image(nsImage: logo).resizable().scaledToFit()
        } else if let icon = file.iconLink, let url = URL(string: icon) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Image(systemName: driveSymbolName(for: file.mimeType))
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.7))
            }
        } else {
            Image(systemName: driveSymbolName(for: file.mimeType))
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    // --- Gmail ---

    @ViewBuilder
    private var gmailContent: some View {
        if !driveAuth.isConnected {
            connectPrompt(logo: GoogleAssets.gmail, fallbackSymbol: "envelope.fill", title: "Connect your Gmail")
        } else if !driveAuth.hasScope(GoogleScopes.gmail) {
            connectPrompt(logo: GoogleAssets.gmail, fallbackSymbol: "envelope.fill",
                          title: "Reconnect for Gmail",
                          subtitle: "Reconnect your Google account to grant access to your Gmail.")
        } else {
            remoteScroll(isLoading: gmailService.isLoading, isEmpty: gmailService.messages.isEmpty,
                         emptyText: viewModel.searchText.isEmpty ? "No emails" : "No matching emails",
                         error: gmailService.errorMessage) {
                ForEach(gmailService.messages) { message in
                    gmailTile(message)
                }
            }
        }
    }

    private func gmailTile(_ message: GmailMessage) -> some View {
        remoteTile(
            action: { open("https://mail.google.com/mail/u/0/#all/\(message.id)") },
            help: "\(message.from) — \(message.subject)"
        ) {
            VStack(alignment: .leading, spacing: 4) {
                Text(message.from)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(message.subject)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                Text(message.snippet)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // --- Calendar ---

    @ViewBuilder
    private var calendarContent: some View {
        if !driveAuth.isConnected {
            connectPrompt(logo: GoogleAssets.calendar, fallbackSymbol: "calendar", title: "Connect your Google Calendar")
        } else if !driveAuth.hasScope(GoogleScopes.calendar) {
            connectPrompt(logo: GoogleAssets.calendar, fallbackSymbol: "calendar",
                          title: "Reconnect for Calendar",
                          subtitle: "Reconnect your Google account to grant access to your Calendar.")
        } else {
            remoteScroll(isLoading: calendarService.isLoading, isEmpty: calendarService.events.isEmpty,
                         emptyText: viewModel.searchText.isEmpty ? "No upcoming events" : "No matching events",
                         error: calendarService.errorMessage) {
                ForEach(calendarService.events) { event in
                    calendarTile(event)
                }
            }
        }
    }

    private func calendarTile(_ event: CalendarEvent) -> some View {
        remoteTile(action: { open(event.htmlLink) }, help: event.summary) {
            VStack(alignment: .leading, spacing: 4) {
                Text(event.dateLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                Text(event.summary)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func connectSlack() {
        Task { await slack.connect() }
    }

    // --- Global search (All tab) ---

    private var globalSearchContent: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(filteredItems) { item in
                    ShelfItemView(item: item, store: store, viewModel: viewModel, reorder: reorder) {
                        handleItemEdit(item)
                    }
                }

                if showsDriveResults {
                    searchSectionLabel("Drive", GoogleAssets.drive, "externaldrive.fill")
                    ForEach(driveService.files) { driveTile($0) }
                }
                if showsMailResults {
                    searchSectionLabel("Mail", GoogleAssets.gmail, "envelope.fill")
                    ForEach(gmailService.messages) { gmailTile($0) }
                }
                if showsCalendarResults {
                    searchSectionLabel("Calendar", GoogleAssets.calendar, "calendar")
                    ForEach(calendarService.events) { calendarTile($0) }
                }
                if showsNotionResults {
                    searchSectionLabel("Notion", NotionAssets.logo, "doc.text")
                    ForEach(notionSearchResults) { notionTile($0) }
                }
                if showsSlackResults {
                    searchSectionLabel("Slack", SlackAssets.logo, "number")
                    ForEach(slackSearchResults) { slackTile($0) }
                }

                if globalSearchEmpty {
                    Text(globalSearchLoading ? "Searching…" : "No results")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(height: Self.tileSide)
                        .padding(.horizontal, 8)
                }
            }
        }
        .frame(height: Self.tileSide)
    }

    private var showsDriveResults: Bool {
        driveAuth.isConnected && driveAuth.hasScope(GoogleScopes.drive) && !driveService.files.isEmpty
    }
    private var showsMailResults: Bool {
        driveAuth.isConnected && driveAuth.hasScope(GoogleScopes.gmail) && !gmailService.messages.isEmpty
    }
    private var showsCalendarResults: Bool {
        driveAuth.isConnected && driveAuth.hasScope(GoogleScopes.calendar) && !calendarService.events.isEmpty
    }
    private var notionSearchResults: [NotionPage] {
        let q = trimmedQuery
        guard notionAuth.isConnected, !q.isEmpty else { return [] }
        return notionService.pages.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }
    private var showsNotionResults: Bool { !notionSearchResults.isEmpty }
    private var slackSearchResults: [SlackChannel] {
        let q = trimmedQuery
        guard !q.isEmpty else { return [] }
        return slack.channels.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }
    private var showsSlackResults: Bool { !slackSearchResults.isEmpty }
    private var globalSearchEmpty: Bool {
        filteredItems.isEmpty && !showsDriveResults && !showsMailResults
            && !showsCalendarResults && !showsNotionResults && !showsSlackResults
    }
    private var globalSearchLoading: Bool {
        driveAuth.isConnected
            && (driveService.isLoading || gmailService.isLoading || calendarService.isLoading)
    }

    private func slackTile(_ channel: SlackChannel) -> some View {
        remoteTile(action: { slack.open(channel) }, help: "#\(channel.name) · \(channel.teamName)") {
            VStack(spacing: 6) {
                Group {
                    if let logo = SlackAssets.logo {
                        Image(nsImage: logo).resizable().scaledToFit()
                    } else {
                        Image(systemName: "number").resizable().scaledToFit()
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .frame(width: 24, height: 24)
                Text("#\(channel.name)")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1).truncationMode(.middle)
                Text(channel.teamName)
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A narrow labelled column separating result groups in the combined search.
    private func searchSectionLabel(_ title: String, _ logo: NSImage?, _ fallback: String) -> some View {
        VStack(spacing: 5) {
            googleLogo(logo, fallback: fallback).frame(width: 16, height: 16)
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(width: 52, height: Self.tileSide)
    }

    private func handleItemEdit(_ item: ShelfItem) {
        if case .snippet(let trigger, let replacement) = item.payload {
            snippetDraft = SnippetDraft(id: item.id, trigger: trigger, replacement: replacement)
            viewModel.isEditingSnippet = true
        } else if case .note = item.payload {
            openNote(item.id)
        }
    }

    // --- Shared building blocks ---

    private func remoteScroll<Content: View>(
        isLoading: Bool,
        isEmpty: Bool,
        emptyText: String = "Nothing to show",
        error: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if let error, isEmpty {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.orange.opacity(0.9))
                        .frame(width: 420, alignment: .leading)
                        .frame(height: Self.tileSide)
                        .fixedSize(horizontal: false, vertical: true)
                } else if isLoading && isEmpty {
                    ProgressView().controlSize(.small).tint(.white).frame(height: Self.tileSide)
                } else if isEmpty {
                    Text(emptyText)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(height: Self.tileSide)
                } else {
                    content()
                }
            }
        }
        .frame(height: Self.tileSide)
    }

    private func remoteTile<Content: View>(
        action: @escaping () -> Void,
        help: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content()
                .padding(8)
                .frame(width: 130, height: Self.tileSide)
                .background(FrostedBackground(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func connectPrompt(logo: NSImage?, fallbackSymbol: String, title: String, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                googleLogo(logo, fallback: fallbackSymbol).frame(width: 18, height: 18)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text(subtitle ?? (driveAuth.hasCredentials
                 ? "Sign in with your Google account to use this from the notch."
                 : "Google isn't configured in this build yet."))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
            if let error = driveAuth.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.orange.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                connectGoogle()
            } label: {
                HStack(spacing: 6) {
                    if driveAuth.isConnecting {
                        ProgressView().controlSize(.small).tint(.white)
                    }
                    Text(driveAuth.isConnecting ? "Connecting…" : "Connect")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.2)))
            }
            .buttonStyle(.plain)
            .disabled(driveAuth.isConnecting)
        }
        .frame(maxWidth: 360, alignment: .leading)
        .frame(height: Self.tileSide, alignment: .top)
    }

    private func googleLogo(_ image: NSImage?, fallback: String) -> some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill().clipShape(Circle())
            } else {
                Image(systemName: fallback)
                    .resizable().scaledToFit()
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    private func open(_ link: String?) {
        guard let link, let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - New-email notification

    private static let emailBannerWidth: CGFloat = 60
    /// How far the banner's right edge tucks under the notch (hidden by the bar).
    private static let emailBannerTuck: CGFloat = 16

    /// Centered by the ZStack, then shifted so the banner's right edge tucks just
    /// under the bar's left edge — it reads as sliding out from the compact bar.
    private var emailBannerOffsetX: CGFloat {
        let leftEdge = barLeftEdge != 0 ? barLeftEdge : -(metrics.notchWidth / 2)
        return leftEdge + Self.emailBannerTuck - Self.emailBannerWidth / 2
    }

    private var emailBannerShape: NotchTabShape {
        NotchTabShape(topCornerRadius: 10, bottomCornerRadius: 13)
    }

    /// The Gmail logo without any rounding (squared), for the notification.
    private var gmailNotificationLogo: some View {
        Group {
            if let logo = GoogleAssets.gmail {
                Image(nsImage: logo).resizable().scaledToFit()
            } else {
                Image(systemName: "envelope.fill").resizable().scaledToFit()
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    private func emailBannerView(_ email: IncomingEmail) -> some View {
        gmailNotificationLogo
            .frame(width: 20, height: 20)
            .overlay(alignment: .topTrailing) {
                Text(email.count > 99 ? "99+" : "\(email.count)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color(hex: "#FFFFFF") ?? .white)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 14, minHeight: 14)
                    .background(Capsule().fill(Color(hex: "#FF002E") ?? .red))
                    .offset(x: 7, y: -6)
            }
            .padding(.leading, 16)
            .padding(.trailing, Self.emailBannerTuck)
            .frame(width: Self.emailBannerWidth, height: metrics.notchHeight, alignment: .leading)
            .background(emailBannerShape.fill(Color.black))
            .clipShape(emailBannerShape)
            .contentShape(emailBannerShape)
            .onTapGesture { openEmailBanner() }
            .help("Open Gmail")
    }

    // MARK: - Slack notification banner

    /// Mirrors the Gmail banner: tucked left of the notch, same width/shape, with
    /// the Slack logo and a count pastille.
    private var slackBannerOffsetX: CGFloat {
        let leftEdge = barLeftEdge != 0 ? barLeftEdge : -(metrics.notchWidth / 2)
        return leftEdge + Self.emailBannerTuck - Self.emailBannerWidth / 2
    }

    /// The Slack logo squared, for the notification.
    private var slackNotificationLogo: some View {
        Group {
            if let logo = SlackAssets.logo {
                Image(nsImage: logo).resizable().scaledToFit()
            } else {
                Image(systemName: "message.fill").resizable().scaledToFit()
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    private func slackBannerView(_ message: SlackMessage) -> some View {
        slackNotificationLogo
            .frame(width: 20, height: 20)
            .overlay(alignment: .topTrailing) {
                Text(message.count > 99 ? "99+" : "\(message.count)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color(hex: "#FFFFFF") ?? .white)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 14, minHeight: 14)
                    .background(Capsule().fill(Color(hex: "#FF002E") ?? .red))
                    .offset(x: 7, y: -6)
            }
            .padding(.leading, 16)
            .padding(.trailing, Self.emailBannerTuck)
            .frame(width: Self.emailBannerWidth, height: metrics.notchHeight, alignment: .leading)
            .background(emailBannerShape.fill(Color.black))
            .clipShape(emailBannerShape)
            .contentShape(emailBannerShape)
            .onTapGesture { openSlackBanner(message) }
            .help("Open in Slack")
    }

    private func openEmailBanner() {
        let base = "https://mail.google.com/mail/"
        let urlString: String
        if let email = driveAuth.accountEmail, !email.isEmpty {
            urlString = "\(base)u/\(email)/#inbox"
        } else {
            urlString = base
        }
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
        dismissEmailBanner()
    }

    private func openSlackBanner(_ message: SlackMessage) {
        let url = message.openURL ?? URL(string: "slack://open")
        if let url { NSWorkspace.shared.open(url) }
        dismissSlackBanner()
    }

    private func dismissEmailBanner() {
        emailBannerTask?.cancel()
        withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) { emailBanner = nil }
    }

    private func dismissSlackBanner() {
        slackBannerTask?.cancel()
        withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) { slackBanner = nil }
    }

    private func showEmailBanner(_ email: IncomingEmail) {
        emailBannerTask?.cancel()
        withAnimation(.spring(response: 0.95, dampingFraction: 0.86)) {
            emailBanner = email
        }
        emailBannerTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.85, dampingFraction: 0.92)) {
                emailBanner = nil
            }
        }
    }

    private func showSlackBanner(_ message: SlackMessage) {
        slackBannerTask?.cancel()
        withAnimation(.spring(response: 0.95, dampingFraction: 0.86)) {
            slackBanner = message
        }
        slackBannerTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.85, dampingFraction: 0.92)) {
                slackBanner = nil
            }
        }
    }

    // MARK: - Screenshot saved banner

    private func screenshotBannerView(_ item: ShelfItem) -> some View {
        Group {
            if case .image(_, _, let image) = item.payload {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "camera.viewfinder").resizable().scaledToFit()
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "camera.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color(hex: "#FFFFFF") ?? .white)
                .padding(2)
                .background(Circle().fill(Color.accentColor))
                .offset(x: 5, y: 4)
        }
        .padding(.leading, 16)
        .padding(.trailing, Self.emailBannerTuck)
        .frame(width: Self.emailBannerWidth, height: metrics.notchHeight, alignment: .leading)
        .background(emailBannerShape.fill(Color.black))
        .clipShape(emailBannerShape)
        .help("Screenshot saved to your shelf")
    }

    private func showScreenshotBanner(_ item: ShelfItem) {
        screenshotBannerTask?.cancel()
        withAnimation(.spring(response: 0.95, dampingFraction: 0.86)) {
            screenshotBanner = item
        }
        screenshotBannerTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.85, dampingFraction: 0.92)) {
                screenshotBanner = nil
            }
        }
    }

    private func connectGoogle() {
        Task {
            await driveAuth.connect()
            if driveAuth.isConnected {
                viewModel.setPanelHover(true)
                remoteSearchIfNeeded()
            }
        }
    }

    /// Refresh the active Google tab when its query changes. On the "All" tab a
    /// non-empty query searches every connected Google source at once.
    private func remoteSearchIfNeeded() {
        let query = trimmedQuery
        // Notion pages + Slack channels are filtered client-side and don't depend
        // on Google — just make sure they're loaded for universal search.
        if notionAuth.isConnected, notionService.pages.isEmpty { notionService.loadPages() }
        slack.ensureChannelsLoaded()

        guard driveAuth.isConnected else { return }
        switch selection {
        case .drive:
            query.isEmpty ? driveService.loadRecent() : driveService.search(query)
        case .gmail:
            query.isEmpty ? gmailService.loadRecent() : gmailService.search(query)
        case .calendar:
            query.isEmpty ? calendarService.loadUpcoming() : calendarService.search(query)
        case .all:
            guard !query.isEmpty else { return }
            if driveAuth.hasScope(GoogleScopes.drive) { driveService.search(query) }
            if driveAuth.hasScope(GoogleScopes.gmail) { gmailService.search(query) }
            if driveAuth.hasScope(GoogleScopes.calendar) { calendarService.search(query) }
        default:
            break
        }
    }

    // MARK: - Spotlight actions (web search + Ask AI)

    private var searchActions: some View {
        VStack(spacing: 5) {
            Button { openWebSearch(trimmedQuery) } label: {
                searchActionRow(icon: "magnifyingglass", label: "Search the web for “\(trimmedQuery)”")
            }
            .buttonStyle(.plain)
            Button { askAI(trimmedQuery) } label: {
                searchActionRow(icon: "sparkles", label: "Ask AI: “\(trimmedQuery)”")
            }
            .buttonStyle(.plain)
        }
    }

    private func searchActionRow(icon: String, label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .frame(width: 18)
                .foregroundStyle(.white.opacity(0.7))
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
        .contentShape(Rectangle())
    }

    private var aiAnswerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
                Text(trimmedQuery)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(OpenAIConfig.model)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                Button { exitAI() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white.opacity(0.72), .black.opacity(0.35))
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
            }

            Group {
                if openAI.isLoading && openAI.answer.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).tint(.white)
                        Text("Thinking…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if let error = openAI.errorMessage {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.orange.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView {
                        Text(openAI.answer)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.9))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(height: 220)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openWebSearch(_ query: String) {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        if let url = URL(string: "https://www.google.com/search?q=\(encoded)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func askAI(_ query: String) {
        aiMode = true
        viewModel.setPanelHover(true)
        openAI.ask(query)
    }

    private func exitAI() {
        aiMode = false
        openAI.reset()
    }

    // MARK: - Meeting recording control (extends from the left of the notch)

    /// Extra overlap (beyond the email tuck) so the tab slides under the bar's
    /// bottom-left corner and reads as one continuous block.
    private static let meetingTuck: CGFloat = emailBannerTuck + 5

    /// Right edge tucks under the bar's left edge — reads as an extension of the
    /// compact shelf, like the Gmail notification but persistent.
    private var meetingTabOffsetX: CGFloat {
        let leftEdge = barLeftEdge != 0 ? barLeftEdge : -(metrics.notchWidth / 2)
        return leftEdge + Self.meetingTuck - meetingTabWidthMeasured / 2
    }

    /// Tab sizes to its content + the leading padding + the under-bar tuck; the
    /// width is measured so the right edge can sit under the bar.
    private var meetingTabView: some View {
        HStack(spacing: 0) {
            meetingTabBody
                .padding(.leading, 16)
                .padding(.trailing, 0)
            Spacer(minLength: 0).frame(width: Self.meetingTuck)
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: metrics.notchHeight)
        .background(emailBannerShape.fill(Color.black))
        .clipShape(emailBannerShape)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: MeetingTabWidthKey.self, value: proxy.size.width)
        })
        .onPreferenceChange(MeetingTabWidthKey.self) { meetingTabWidthMeasured = $0 }
    }

    @ViewBuilder
    private var meetingTabBody: some View {
        switch meeting.state {
        case .prompt:
            HStack(spacing: 8) {
                Button { meeting.startRecording() } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Color.red).frame(width: 9, height: 9)
                        Text("Record").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                Button { meeting.dismissPrompt() } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        case .recording:
            // Fixed, comfortable hover region (doesn't resize on hover → no
            // flicker); bars and stop crossfade inside it, centered.
            ZStack {
                audioVisualizer
                    .opacity(meetingHoverStop ? 0 : 1)
                    .scaleEffect(meetingHoverStop ? 0.7 : 1)
                Button { meeting.stopRecording() } label: {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.red)
                        .frame(width: 13, height: 13)
                }
                .buttonStyle(.plain)
                .help("Stop & summarize")
                .opacity(meetingHoverStop ? 1 : 0)
                .scaleEffect(meetingHoverStop ? 1 : 0.4)
                .allowsHitTesting(meetingHoverStop)
            }
            .frame(height: metrics.notchHeight)
            .contentShape(Rectangle())
            .onHover { meetingHoverStop = $0 }
            .animation(.easeInOut(duration: 0.2), value: meetingHoverStop)
        case .processing:
            ShimmerText(text: "Summarizing")
        case .error(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 10)).foregroundStyle(.orange.opacity(0.95))
                    .lineLimit(2).frame(maxWidth: 230)
                Button { meeting.dismissError() } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        case .idle:
            EmptyView()
        }
    }

    private var audioVisualizer: some View {
        HStack(spacing: 2.5) {
            ForEach(Array(meeting.levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 2.5, height: 3 + CGFloat(level) * 26)
            }
        }
        .frame(height: metrics.notchHeight)
        .animation(.easeInOut(duration: 0.32), value: meeting.levels)
    }

    // MARK: - Now playing (media controller)

    private func mediaCard(_ track: NowPlayingTrack) -> some View {
        HStack(spacing: 12) {
            mediaArtwork(track)
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                if !track.album.isEmpty {
                    Text(track.album)
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                Text(track.artist)
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)

                HStack(spacing: 20) {
                    Button { nowPlaying.previous() } label: { Image(systemName: "backward.fill") }
                    Button { nowPlaying.playPause() } label: {
                        Image(systemName: track.isPlaying ? "pause.fill" : "play.fill")
                    }
                    Button { nowPlaying.next() } label: { Image(systemName: "forward.fill") }
                }
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .buttonStyle(.plain)
                .padding(.top, 5)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GeometryReader { geo in
            Color.clear.preference(key: AudioCardHeightKey.self, value: geo.size.height)
        })
    }

    @ViewBuilder
    private func mediaArtwork(_ track: NowPlayingTrack) -> some View {
        if let url = track.artworkURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                mediaArtworkPlaceholder
            }
        } else {
            mediaArtworkPlaceholder
        }
    }

    private var mediaArtworkPlaceholder: some View {
        ZStack {
            Color.white.opacity(0.08)
            Image(systemName: "music.note").font(.system(size: 22)).foregroundStyle(.white.opacity(0.4))
        }
    }

    // Compact now-playing tab (left of the notch, collapsed state).

    private static let nowPlayingTuck: CGFloat = meetingTuck
    private var nowPlayingTabWidth: CGFloat { 16 + 24 + 0 + Self.nowPlayingTuck }

    private var nowPlayingOffsetX: CGFloat {
        let leftEdge = barLeftEdge != 0 ? barLeftEdge : -(metrics.notchWidth / 2)
        return leftEdge + Self.nowPlayingTuck - nowPlayingTabWidth / 2
    }

    private func nowPlayingCompactTab(_ track: NowPlayingTrack) -> some View {
        HStack(spacing: 0) {
            ZStack {
                mediaArtwork(track)
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .opacity(nowPlayingHover ? 0 : 1)
                Button { nowPlaying.playPause() } label: {
                    Image(systemName: track.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .opacity(nowPlayingHover ? 1 : 0)
                .allowsHitTesting(nowPlayingHover)
            }
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .onHover { nowPlayingHover = $0 }
            .animation(.easeInOut(duration: 0.18), value: nowPlayingHover)
            .padding(.leading, 16)
            .padding(.trailing, 0)
            Spacer(minLength: 0).frame(width: Self.nowPlayingTuck)
        }
        .frame(width: nowPlayingTabWidth, height: metrics.notchHeight)
        .background(emailBannerShape.fill(Color.black))
        .clipShape(emailBannerShape)
    }

    private var noteEditorView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Note")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                Button { closeNoteEditor() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white.opacity(0.72), .black.opacity(0.35))
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            NoteEditor(
                text: noteBinding,
                slash: slash,
                shouldFocus: true,
                onBeginEditing: { viewModel.isEditingNote = true }
            )
            .frame(height: 160)
            // No background — the shelf's frosted gradient shows through.
            .padding(.vertical, 2)

            if slash.active {
                slashMenu
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var slashMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(slash.matches.enumerated()), id: \.element) { index, command in
                Button {
                    slash.apply?(command)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: command.systemImage)
                            .font(.system(size: 11))
                            .frame(width: 16)
                        Text(command.title)
                            .font(.system(size: 12))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.white.opacity(index == slash.highlight ? 1 : 0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(index == slash.highlight ? Color.white.opacity(0.16) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .frame(maxWidth: 240, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(white: 0.16)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
    }

    private var noteBinding: Binding<String> {
        Binding(
            get: { editingNoteId.flatMap { store.noteContent($0) } ?? "" },
            set: { if let id = editingNoteId { store.setNoteContent(id, $0) } }
        )
    }

    private func openNote(_ id: UUID) {
        tab = .notes
        editingNoteId = id
        viewModel.isEditingNote = true
    }

    private func openNewNote() {
        openNote(store.addNote(folderId: currentFolderId))
    }

    private func closeNoteEditor() {
        // Discard a note left empty.
        if let id = editingNoteId,
           (store.noteContent(id) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let item = store.items.first(where: { $0.id == id }) {
            store.remove(item)
        }
        editingNoteId = nil
        viewModel.isEditingNote = false
        slash.reset()
    }

    private var snippetEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Trigger")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
            PlainTextField(
                text: snippetBinding(\.trigger),
                placeholder: "e.g. ;addr",
                shouldFocus: true,
                onBeginEditing: { viewModel.isEditingSnippet = true }
            )
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))

            Text("Replacement")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
            PlainTextField(
                text: snippetBinding(\.replacement),
                placeholder: "Replacement text",
                onBeginEditing: { viewModel.isEditingSnippet = true }
            )
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { closeSnippetEditor() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.6))
                Button("Save") { saveSnippet() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.2)))
            }
            .font(.system(size: 12, weight: .medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func snippetBinding(_ keyPath: WritableKeyPath<SnippetDraft, String>) -> Binding<String> {
        Binding(
            get: { snippetDraft?[keyPath: keyPath] ?? "" },
            set: { snippetDraft?[keyPath: keyPath] = $0 }
        )
    }

    private func saveSnippet() {
        guard let draft = snippetDraft else { return }
        store.upsertSnippet(
            id: draft.id,
            trigger: draft.trigger,
            replacement: draft.replacement,
            folderId: currentFolderId
        )
        closeSnippetEditor()
    }

    private func closeSnippetEditor() {
        snippetDraft = nil
        viewModel.isEditingSnippet = false
    }

    @ViewBuilder
    private var searchRow: some View {
        if viewModel.isSearching {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.white.opacity(0.5))
                SearchField(text: $viewModel.searchText) {
                    viewModel.closeSearch()
                }
                .frame(maxWidth: .infinity)
                Button {
                    viewModel.closeSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
        } else {
            HStack {
                Button {
                    viewModel.openSearch(compact: false)
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(6)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
        }
    }

    private enum SettingsSection: String, CaseIterable, Identifiable {
        case account, preferences, connections, widgets
        var id: String { rawValue }
        var title: String {
            switch self {
            case .account: return "Account"
            case .preferences: return "Preferences"
            case .connections: return "Connections"
            case .widgets: return "Widgets"
            }
        }
        var icon: String {
            switch self {
            case .account: return "person.crop.circle"
            case .preferences: return "slider.horizontal.3"
            case .connections: return "link"
            case .widgets: return "square.grid.2x2"
            }
        }
    }

    /// The gear button — opens the settings popover.
    private var settingsMenu: some View {
        Button { showSettings = true } label: {
            Image(systemName: "gearshape")
                .symbolRenderingMode(.palette)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(6)
                .background(Capsule().fill(Color.white.opacity(0.10)))
        }
        .buttonStyle(.plain)
        .help("Settings")
    }

    private func closeSettings() {
        showSettings = false
        supabase.authError = nil
    }

    // MARK: - Settings popover (sidebar + panes)

    private var settingsOverlay: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { closeSettings() }
            settingsPanel
                .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
        .environment(\.colorScheme, .dark)
        .onExitCommand { closeSettings() }
    }

    private var settingsPanel: some View {
        HStack(spacing: 0) {
            settingsSidebar
            Divider().overlay(Color.white.opacity(0.08))
            settingsContent
        }
        .frame(width: 580, height: 400)
        .background(settingsShelfBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(10)
        .background(VisualEffectBlur())
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Button(action: closeSettings) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .padding(16)
        }
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Settings")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 10).padding(.bottom, 4)
            ForEach(SettingsSection.allCases) { s in
                Button { settingsSection = s } label: {
                    HStack(spacing: 9) {
                        Image(systemName: s.icon).font(.system(size: 12)).frame(width: 16)
                        Text(s.title).font(.system(size: 13, weight: settingsSection == s ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(settingsSection == s ? .white : .white.opacity(0.6))
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(settingsSection == s ? Color.white.opacity(0.12) : .clear))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            Button { NSApplication.shared.terminate(nil) } label: {
                HStack(spacing: 9) {
                    Image(systemName: "power").font(.system(size: 12)).frame(width: 16)
                    Text("Quit Notchboard").font(.system(size: 12))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white.opacity(0.45))
                .padding(.horizontal, 10).padding(.vertical, 7)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 170)
    }

    @ViewBuilder
    private var settingsContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                switch settingsSection {
                case .account: accountPane
                case .preferences: preferencesPane
                case .connections: connectionsPane
                case .widgets: widgetsPane
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func settingsTitle(_ t: String) -> some View {
        Text(t).font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
    }

    // MARK: Account pane

    @ViewBuilder
    private var accountPane: some View {
        if supabase.isSignedIn {
            settingsTitle("Account")
            VStack(alignment: .leading, spacing: 3) {
                Text("Signed in as").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                Text(supabase.userEmail ?? "—").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
            }
            syncBox
            Button { Task { await supabase.signOut() } } label: {
                Text("Sign out").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(Capsule().fill(Color.white.opacity(0.16)))
            }
            .buttonStyle(.plain)
        } else {
            settingsTitle(authIsSignUp ? "Create account" : "Sign in")
            Text("Sync your shelf across your devices.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            authField(icon: "envelope", placeholder: "Email", text: $authEmail, secure: false)
            authField(icon: "lock", placeholder: "Password", text: $authPassword, secure: true)
            if let error = supabase.authError {
                Text(error).font(.system(size: 11)).foregroundStyle(Color.orange.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if supabase.pendingConfirmation {
                Text("Check your inbox to confirm your email, then sign in.")
                    .font(.system(size: 11)).foregroundStyle(Color.green.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                Task {
                    if authIsSignUp { await supabase.signUp(email: authEmail, password: authPassword) }
                    else { await supabase.signIn(email: authEmail, password: authPassword) }
                }
            } label: {
                HStack(spacing: 8) {
                    if supabase.isWorking { ProgressView().controlSize(.small).tint(.white) }
                    Text(authIsSignUp ? "Create account" : "Sign in").font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            .disabled(supabase.isWorking || authEmail.isEmpty || authPassword.isEmpty)
            .opacity(supabase.isWorking || authEmail.isEmpty || authPassword.isEmpty ? 0.6 : 1)
            Button { authIsSignUp.toggle(); supabase.authError = nil } label: {
                Text(authIsSignUp ? "Already have an account? Sign in" : "No account yet? Create one")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
    }

    private var syncBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sync online").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Text("Store your shelf in the cloud so it's available on your other devices. Off = this Mac only.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Toggle("", isOn: $sync.syncEnabled).labelsHidden().toggleStyle(.switch).tint(.accentColor)
            }
            if sync.syncEnabled, !sync.status.isEmpty {
                Text(sync.status).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func authField(icon: String, placeholder: String, text: Binding<String>, secure: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).frame(width: 16)
            Group {
                if secure { SecureField(placeholder, text: text) } else { TextField(placeholder, text: text) }
            }
            .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(.white)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    // MARK: Preferences pane

    private var preferencesPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsTitle("Preferences")
            VStack(alignment: .leading, spacing: 8) {
                Text("Open shelf").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Picker("", selection: $persistentSettings.openMode) {
                    ForEach(ShelfOpenMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Dash sections").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                ForEach(DashSection.allCases) { section in
                    Toggle(isOn: Binding(
                        get: { persistentSettings.isDashSectionOn(section) },
                        set: { _ in persistentSettings.toggleDashSection(section) }
                    )) {
                        Text(section.title).font(.system(size: 13)).foregroundStyle(.white)
                    }
                    .toggleStyle(.switch).tint(.accentColor)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Connections pane

    private var connectionsPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsTitle("Connections")
            connectionRow(
                title: "Google", logo: GoogleAssets.drive, fallback: "externaldrive.fill",
                connected: driveAuth.isConnected, detail: driveAuth.accountEmail,
                busy: driveAuth.isConnecting,
                connect: { connectGoogle() }, disconnect: { driveAuth.disconnect() })
            connectionRow(
                title: "Notion", logo: NotionAssets.logo, fallback: "doc.text",
                connected: notionAuth.isConnected, detail: notionAuth.workspaceName,
                busy: notionAuth.isConnecting,
                connect: { connectNotion() }, disconnect: { notionAuth.disconnect(); notionService.clear() })
            slackConnectionRow
            Spacer(minLength: 0)
        }
    }

    private func connectionRow(title: String, logo: NSImage?, fallback: String,
                               connected: Bool, detail: String?, busy: Bool,
                               connect: @escaping () -> Void, disconnect: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            connLogo(logo, fallback)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                if connected {
                    Text(detail ?? "Connected").font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45)).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if connected {
                Button("Disconnect", action: disconnect)
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
            } else {
                Button(busy ? "Connecting…" : "Connect", action: connect)
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor).disabled(busy)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    private var slackConnectionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                connLogo(SlackAssets.logo, "number")
                Text("Slack").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                Spacer(minLength: 8)
                Button(slack.isConnecting ? "Connecting…" : (slack.workspaces.isEmpty ? "Connect" : "Add"),
                       action: { connectSlack() })
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor).disabled(slack.isConnecting)
            }
            ForEach(slack.workspaces) { ws in
                HStack(spacing: 8) {
                    Text(ws.teamName).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    Spacer(minLength: 8)
                    Button("Disconnect") { slack.disconnect(ws.teamId) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
                .padding(.leading, 32)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func connLogo(_ image: NSImage?, _ fallback: String) -> some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: fallback).resizable().scaledToFit().foregroundStyle(.white.opacity(0.8)) }
        }
        .frame(width: 22, height: 22)
    }

    // MARK: Widgets pane

    private var widgetsPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsTitle("Widgets")
            Text("Choose what sits on either side of the notch in the always-visible bar.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
            Button {
                closeSettings()
                openWidgetConfigurator()
            } label: {
                Label("Customize widgets", systemImage: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Capsule().fill(Color.white.opacity(0.16)))
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
    }

    private var settingsShelfBackground: some View {
        GeometryReader { geo in
            ZStack {
                VisualEffectBlur()
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: .black, location: 0.0),
                        .init(color: .black.opacity(0.25), location: 1.0),
                    ]),
                    center: UnitPoint(x: 0.25, y: 0.0),
                    startRadius: 0,
                    endRadius: hypot(geo.size.width, geo.size.height)
                )
            }
        }
    }

    private var filterPills: some View {
        HStack(spacing: 6) {
            FilterPill(title: "All", count: itemCount(for: .all), isSelected: selection == .all) {
                selection = .all
            }

            ForEach(presentTypes, id: \.self) { type in
                FilterPill(title: type.title, count: itemCount(for: type), isSelected: selection == type) {
                    selection = type
                }
            }

            FilterPill(
                title: "Drive",
                systemImage: GoogleAssets.drive == nil ? "externaldrive" : nil,
                nsImage: GoogleAssets.drive,
                isSelected: selection == .drive
            ) {
                selection = .drive
                remoteSearchIfNeeded()
            }

            FilterPill(
                title: "Mail",
                systemImage: GoogleAssets.gmail == nil ? "envelope" : nil,
                nsImage: GoogleAssets.gmail,
                isSelected: selection == .gmail
            ) {
                selection = .gmail
                remoteSearchIfNeeded()
            }

            FilterPill(
                title: "Calendar",
                systemImage: GoogleAssets.calendar == nil ? "calendar" : nil,
                nsImage: GoogleAssets.calendar,
                isSelected: selection == .calendar
            ) {
                selection = .calendar
                remoteSearchIfNeeded()
            }

            ForEach(store.folders) { folder in
                folderPill(folder)
            }
        }
    }

    private func folderPill(_ folder: ShelfFolder) -> some View {
        // NOTE: do NOT attach .onDrop here — on macOS a drop target on a Button
        // swallows its mouseDown and the click stops firing. Filing items is
        // handled via the per-tile folder menu and dropping into the open folder.
        FilterPill(
            title: folder.name,
            systemImage: "folder",
            count: itemCount(for: .folder(folder.id)),
            isSelected: selection == .folder(folder.id)
        ) {
            selection = .folder(folder.id)
        }
        .contextMenu {
            Button("Rename") {
                if let name = promptForFolderName(
                    title: "Rename folder", confirmTitle: "Save", initial: folder.name
                ) {
                    store.renameFolder(folder.id, to: name)
                }
            }
            Button("Delete", role: .destructive) {
                store.deleteFolder(folder.id)
            }
        }
    }

    private func itemCount(for selection: ShelfSelection) -> Int {
        store.items.filter { selection.matches($0) }.count
    }

    private var addMenu: some View {
        Menu {
            Button {
                if let (name, kind) = promptForNewFolder() {
                    store.createFolder(name: name, kind: kind)
                    tab = .assets
                }
            } label: {
                Label("Folder", systemImage: "folder")
            }
            Button {
                let id = store.addColorPlaceholder(folderId: nil)
                tab = .colors
                viewModel.editingColorId = id
            } label: {
                Label("Color", systemImage: "paintpalette")
            }
            Button {
                snippetDraft = SnippetDraft()
                tab = .snippets
                viewModel.isEditingSnippet = true
            } label: {
                Label("Snippet", systemImage: "text.badge.plus")
            }
            Button {
                openNewNote()
            } label: {
                Label("Note", systemImage: "note.text")
            }
        } label: {
            Image(systemName: "plus")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white.opacity(0.8))
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.10)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add")
    }

    private func resetSelectionIfNeeded() {
        switch selection {
        case .all, .drive, .gmail, .calendar:
            break
        case .text, .images, .files, .colors, .snippets, .notes:
            if !presentTypes.contains(selection) { selection = .all }
        case .folder(let id):
            if !store.folders.contains(where: { $0.id == id }) { selection = .all }
        }
    }

    private var emptyHint: some View {
        Text(selection == .all
             ? "Drag text, an image, or a file here"
             : "Nothing here yet")
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.4))
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 8)
    }

    private func updateNotchHover(_ hovering: Bool) {
        isNotchHovering = hovering
        switch persistentSettings.openMode {
        case .hover:
            viewModel.setNotchHover(hovering)
        case .click:
            viewModel.setNotchHover(false)
        }
    }

    private func openWidgetConfigurator() {
        viewModel.isConfiguringWidgets = true
        viewModel.setPanelHover(true)
    }

    private func widgetDragProvider(for kind: WidgetKind) -> NSItemProvider {
        let provider = NSItemProvider(object: kind.rawValue as NSString)
        provider.registerDataRepresentation(
            forTypeIdentifier: Self.widgetType.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(Data(kind.rawValue.utf8), nil)
            return nil
        }
        return provider
    }

    private func presentImportPanel() {
        guard !isImportPanelSuppressed else { return }
        importPanelCloseTask?.cancel()
        importPanelCloseTask = nil
        isImportPanelPresented = true
        viewModel.setNotchHover(false)
        viewModel.setPanelHover(false)
    }

    private func scheduleImportPanelClose(after delay: UInt64 = 2_000_000_000) {
        importPanelCloseTask?.cancel()
        importPanelCloseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled,
                  !isImportNotchTargeted,
                  !isImportPanelTargeted,
                  !isImportDropTargeted else { return }
            dismissImportPanel()
        }
    }

    private func dismissImportPanel() {
        importPanelCloseTask?.cancel()
        importPanelCloseTask = nil
        isImportPanelPresented = false
        isImportNotchTargeted = false
        isImportPanelTargeted = false
        isImportDropTargeted = false
    }

    private func suppressImportPanelReopen() {
        importPanelSuppressTask?.cancel()
        isImportPanelSuppressed = true
        importPanelSuppressTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            isImportPanelSuppressed = false
            importPanelSuppressTask = nil
        }
    }

    private func performImportDrop(_ providers: [NSItemProvider]) -> Bool {
        let handled = handleDrop(providers, revealAfterDrop: true)
        if handled {
            suppressImportPanelReopen()
            showShelfAfterImport(revealing: nil)
        } else {
            dismissImportPanel()
        }
        return handled
    }

    private func showShelfAfterImport(revealing id: UUID?) {
        dismissImportPanel()
        tab = .assets
        if let id {
            revealItemId = id
        }
        viewModel.setPanelHover(true)
    }

    private func handleDrop(_ providers: [NSItemProvider], revealAfterDrop: Bool = false) -> Bool {
        // An internal tile being dragged (reorder) carries our item type — never
        // re-add it as new content (that would duplicate it). Reaching the shelf
        // means it was dropped on the background, so just end the drag.
        let isInternal = reorder.draggedId != nil
            || providers.contains { $0.hasItemConformingToTypeIdentifier(Self.itemType.identifier) }
        reorder.draggedId = nil
        dropTargetId = nil
        if isInternal { return false }

        // Capture the open folder now so dropped content lands there, even if
        // the async loads finish later.
        let folderId = currentFolderId
        var handled = false
        for provider in providers {
            // A dropped file (from Finder, etc.) is handled first: real images
            // become thumbnails, anything else is kept as a file item.
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    let url = url(from: item)
                    guard let url else { return }
                    if isImageFile(url) {
                        addImage(from: provider, fallbackURL: url, folderId: folderId, revealAfterDrop: revealAfterDrop)
                    } else {
                        Task { @MainActor in
                            let id = store.addFile(url, folderId: folderId)
                            if revealAfterDrop { showShelfAfterImport(revealing: id) }
                        }
                    }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                // An image dragged from an app/browser with no backing file.
                handled = true
                _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                    guard let image = object as? NSImage else { return }
                    addImage(from: provider, fallbackImage: image, folderId: folderId, revealAfterDrop: revealAfterDrop)
                }
            } else if provider.canLoadObject(ofClass: NSString.self)
                        || provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
                        || provider.hasItemConformingToTypeIdentifier(UTType.html.identifier) {
                // Text, a URL, or HTML. If it resolves to a remote image (e.g. an
                // image dragged from a web page that only handed us its URL), fetch
                // the bytes and store it as an image — no manual download needed.
                handled = true
                resolveRemoteImageURL(from: provider) { imageURL in
                    if let imageURL {
                        downloadAndAddImage(imageURL, folderId: folderId, revealAfterDrop: revealAfterDrop)
                    } else {
                        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                            guard let string = object as? NSString else { return }
                            Task { @MainActor in
                                let id = store.addText(string as String, folderId: folderId)
                                if revealAfterDrop { showShelfAfterImport(revealing: id) }
                            }
                        }
                    }
                }
            }
        }
        return handled
    }

    // MARK: - Remote image import (drag from a web page)

    /// Downloads a remote image and stores it, preserving its original format
    /// and name. Used when a web image was dropped as a URL rather than bytes.
    private func downloadAndAddImage(_ url: URL, folderId: UUID?, revealAfterDrop: Bool) {
        Task { @MainActor in
            do {
                var request = URLRequest(url: url)
                // Some CDNs reject requests without a browser-like User-Agent.
                request.setValue(
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                    forHTTPHeaderField: "User-Agent"
                )
                let (data, response) = try await URLSession.shared.data(for: request)
                guard NSImage(data: data) != nil else { return }
                let ext = imageExtension(url: url, response: response)
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(UUID().uuidString).\(ext)")
                try data.write(to: temp)
                let id = store.addImageFile(temp, displayName: imageDownloadName(url: url, ext: ext), folderId: folderId)
                try? FileManager.default.removeItem(at: temp)
                if revealAfterDrop { showShelfAfterImport(revealing: id) }
            } catch {
                // Couldn't fetch — nothing added.
            }
        }
    }

    /// Finds a remote (http/https) image URL in a dropped provider: a direct URL
    /// representation that points to an image, or the first <img> in dropped HTML.
    private func resolveRemoteImageURL(from provider: NSItemProvider, completion: @escaping (URL?) -> Void) {
        loadSourceURL(from: provider) { url in
            if let url, isRemoteImageURL(url) {
                completion(url)
                return
            }
            loadImageURLFromHTML(from: provider, completion: completion)
        }
    }

    private func isRemoteImageURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return imageExtensions.contains(url.pathExtension.lowercased())
    }

    private func loadImageURLFromHTML(from provider: NSItemProvider, completion: @escaping (URL?) -> Void) {
        guard provider.hasItemConformingToTypeIdentifier(UTType.html.identifier)
                || provider.registeredTypeIdentifiers.contains(UTType.html.identifier) else {
            completion(nil)
            return
        }
        provider.loadItem(forTypeIdentifier: UTType.html.identifier) { item, _ in
            completion(html(from: item).flatMap(imageURLFromHTML))
        }
    }

    private func imageURLFromHTML(_ html: String) -> URL? {
        let pattern = #"(?i)(?:https?:)?//[^\s"'<>]+?\.(?:png|jpe?g|gif|webp|heic|heif|tiff?|bmp)(?:\?[^\s"'<>]*)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let matchRange = Range(match.range, in: html) else { return nil }
        let text = String(html[matchRange])
        return URL(string: text.hasPrefix("//") ? "https:\(text)" : text)
    }

    private var imageExtensions: Set<String> {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp"]
    }

    private func imageExtension(url: URL, response: URLResponse) -> String {
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return ext == "jpeg" ? "jpg" : ext }
        switch response.mimeType {
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic", "image/heif": return "heic"
        case "image/tiff": return "tiff"
        case "image/bmp": return "bmp"
        default: return "png"
        }
    }

    private func imageDownloadName(url: URL, ext: String) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let cleaned = (base.removingPercentEncoding ?? base)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (cleaned.isEmpty || cleaned == "/") ? "image" : cleaned
        return "\(name).\(ext)"
    }

    /// A display name for an image. Uses concrete source URLs ahead of generic
    /// provider names like "image" / "untitled".
    private func imageName(from suggested: String?, source: URL? = nil) -> String {
        let sourceName = source?.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceExtension = source?.pathExtension
        let suggestedName = normalizedImageName(suggested, fallbackExtension: sourceExtension)

        if let suggestedName, !isGenericImageName(suggestedName) {
            return suggestedName
        }
        if let sourceName, !sourceName.isEmpty, !isGenericImageName(sourceName) {
            return sourceName
        }
        if let sourceName, !sourceName.isEmpty { return sourceName }
        return suggestedName ?? "image.png"
    }

    private func normalizedImageName(_ name: String?, fallbackExtension: String? = nil) -> String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !(trimmed as NSString).pathExtension.isEmpty {
            return trimmed
        }
        let ext = fallbackExtension?.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(trimmed).\((ext?.isEmpty == false) ? ext! : "png")"
    }

    private func isGenericImageName(_ name: String) -> Bool {
        let base = (name as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ["image", "untitled", "pasted image"].contains(base)
    }

    private func addImage(
        from provider: NSItemProvider,
        fallbackURL: URL? = nil,
        fallbackImage: NSImage? = nil,
        folderId: UUID?,
        revealAfterDrop: Bool = false
    ) {
        loadBestImageFileURL(from: provider, fallback: fallbackURL) { sourceURL in
            if let sourceURL, isImageFile(sourceURL) {
                let name = imageName(from: provider.suggestedName, source: sourceURL)
                Task { @MainActor in
                    let id = store.addImageFile(sourceURL, displayName: name, folderId: folderId)
                    if revealAfterDrop { showShelfAfterImport(revealing: id) }
                }
                return
            }

            let addBitmap: (NSImage, String) -> Void = { image, name in
                Task { @MainActor in
                    let id = store.addImage(image, name: name, folderId: folderId)
                    if revealAfterDrop { showShelfAfterImport(revealing: id) }
                }
            }

            resolvedImageName(from: provider, fallbackURL: fallbackURL) { name in
                if let fallbackImage {
                    addBitmap(fallbackImage, name)
                } else {
                    _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                        guard let image = object as? NSImage else { return }
                        addBitmap(image, name)
                    }
                }
            }
        }
    }

    private func loadBestImageFileURL(
        from provider: NSItemProvider,
        fallback: URL?,
        completion: @escaping (URL?) -> Void
    ) {
        loadFilenamePasteboardURL(from: provider) { filenameURL in
            if let filenameURL, isBetterImageURL(filenameURL, than: fallback) {
                completion(filenameURL)
                return
            }

            loadInPlaceImageFileURL(from: provider) { inPlaceURL in
                if let inPlaceURL, isBetterImageURL(inPlaceURL, than: fallback ?? filenameURL) {
                    completion(inPlaceURL)
                    return
                }

                loadSourceURL(from: provider) { sourceURL in
                    let best = [sourceURL, filenameURL, fallback]
                        .compactMap { $0 }
                        .sorted { lhs, rhs in
                            imageURLScore(lhs) > imageURLScore(rhs)
                        }
                        .first
                    completion(best)
                }
            }
        }
    }

    private func isBetterImageURL(_ candidate: URL, than current: URL?) -> Bool {
        guard candidate.isFileURL else { return false }
        guard let current else { return true }
        return imageURLScore(candidate) > imageURLScore(current)
    }

    private func imageURLScore(_ url: URL) -> Int {
        let name = url.lastPathComponent
        var score = 0
        if url.isFileURL { score += 2 }
        if !name.isEmpty { score += 2 }
        if !isGenericImageName(name) { score += 10 }
        if FileManager.default.fileExists(atPath: url.path) { score += 4 }
        return score
    }

    private func loadFilenamePasteboardURL(from provider: NSItemProvider, completion: @escaping (URL?) -> Void) {
        let identifiers = ["NSFilenamesPboardType", "com.apple.pasteboard.promised-file-url"]
        loadFilenamePasteboardURL(from: provider, identifiers: identifiers, index: 0, completion: completion)
    }

    private func loadFilenamePasteboardURL(
        from provider: NSItemProvider,
        identifiers: [String],
        index: Int,
        completion: @escaping (URL?) -> Void
    ) {
        guard identifiers.indices.contains(index) else {
            completion(nil)
            return
        }

        let identifier = identifiers[index]
        guard provider.hasItemConformingToTypeIdentifier(identifier)
                || provider.registeredTypeIdentifiers.contains(identifier) else {
            loadFilenamePasteboardURL(from: provider, identifiers: identifiers, index: index + 1, completion: completion)
            return
        }

        provider.loadItem(forTypeIdentifier: identifier) { item, _ in
            if let url = fileURLs(from: item).first {
                completion(url)
            } else {
                loadFilenamePasteboardURL(from: provider, identifiers: identifiers, index: index + 1, completion: completion)
            }
        }
    }

    private func loadInPlaceImageFileURL(from provider: NSItemProvider, completion: @escaping (URL?) -> Void) {
        guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
            completion(nil)
            return
        }

        provider.loadInPlaceFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, isInPlace, _ in
            guard let url, isInPlace || !isGenericImageName(url.lastPathComponent) else {
                completion(nil)
                return
            }
            completion(url)
        }
    }

    private func resolvedImageName(from provider: NSItemProvider, completion: @escaping (String) -> Void) {
        resolvedImageName(from: provider, fallbackURL: nil, completion: completion)
    }

    private func resolvedImageName(
        from provider: NSItemProvider,
        fallbackURL: URL?,
        completion: @escaping (String) -> Void
    ) {
        if let suggestedName = normalizedImageName(provider.suggestedName),
           !isGenericImageName(suggestedName) {
            completion(suggestedName)
            return
        }

        loadSourceURL(from: provider) { url in
            let sourceURL = url ?? fallbackURL
            if let sourceURL {
                let name = imageName(from: provider.suggestedName, source: sourceURL)
                if !isGenericImageName(name) {
                    completion(name)
                    return
                }
            }

            loadImageNameFromHTML(from: provider) { htmlName in
                completion(htmlName ?? imageName(from: provider.suggestedName, source: sourceURL))
            }
        }
    }

    private func loadSourceURL(from provider: NSItemProvider, completion: @escaping (URL?) -> Void) {
        let preferredIdentifiers = [
            UTType.fileURL.identifier,
            UTType.url.identifier,
            "com.apple.pasteboard.promised-file-url"
        ]
        let urlIdentifiers = provider.registeredTypeIdentifiers.filter {
            $0.localizedCaseInsensitiveContains("url")
        }
        let identifiers = (preferredIdentifiers + urlIdentifiers).reduce(into: [String]()) { result, identifier in
            if !result.contains(identifier) {
                result.append(identifier)
            }
        }
        loadSourceURL(from: provider, identifiers: identifiers, index: 0, completion: completion)
    }

    private func loadSourceURL(
        from provider: NSItemProvider,
        identifiers: [String],
        index: Int,
        completion: @escaping (URL?) -> Void
    ) {
        guard identifiers.indices.contains(index) else {
            completion(nil)
            return
        }

        let identifier = identifiers[index]
        guard provider.hasItemConformingToTypeIdentifier(identifier)
                || provider.registeredTypeIdentifiers.contains(identifier) else {
            loadSourceURL(from: provider, identifiers: identifiers, index: index + 1, completion: completion)
            return
        }

        provider.loadItem(forTypeIdentifier: identifier) { item, _ in
            if let url = url(from: item), !url.lastPathComponent.isEmpty {
                completion(url)
            } else {
                loadSourceURL(from: provider, identifiers: identifiers, index: index + 1, completion: completion)
            }
        }
    }

    private func loadImageNameFromHTML(from provider: NSItemProvider, completion: @escaping (String?) -> Void) {
        guard provider.hasItemConformingToTypeIdentifier(UTType.html.identifier)
                || provider.registeredTypeIdentifiers.contains(UTType.html.identifier) else {
            completion(nil)
            return
        }

        provider.loadItem(forTypeIdentifier: UTType.html.identifier) { item, _ in
            completion(html(from: item).flatMap(imageNameFromHTML))
        }
    }

    private func html(from item: NSSecureCoding?) -> String? {
        switch item {
        case let data as Data:
            return String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16)
        case let string as String:
            return string
        case let string as NSString:
            return string as String
        default:
            return nil
        }
    }

    private func imageNameFromHTML(_ html: String) -> String? {
        let pattern = #"(?i)(?:https?:)?//[^\s"'<>]+?\.(?:png|jpe?g|gif|webp|heic|tiff?)(?:\?[^\s"'<>]*)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in regex.matches(in: html, range: range) {
            guard let urlRange = Range(match.range, in: html) else { continue }
            let urlText = String(html[urlRange])
            if let url = URL(string: urlText.hasPrefix("//") ? "https:\(urlText)" : urlText) {
                let name = imageName(from: nil, source: url)
                if !isGenericImageName(name) {
                    return name.removingPercentEncoding ?? name
                }
            }
        }
        return nil
    }

    private func url(from item: NSSecureCoding?) -> URL? {
        switch item {
        case let url as URL:
            return url
        case let url as NSURL:
            return url as URL
        case let data as Data:
            return URL(dataRepresentation: data, relativeTo: nil)
        case let string as String:
            return url(from: string)
        case let string as NSString:
            return url(from: string as String)
        default:
            return nil
        }
    }

    private func url(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }
        return URL(string: trimmed)
    }

    private func fileURLs(from item: NSSecureCoding?) -> [URL] {
        switch item {
        case let url as URL:
            return [url]
        case let url as NSURL:
            return [url as URL]
        case let urls as [URL]:
            return urls
        case let urls as [NSURL]:
            return urls.map { $0 as URL }
        case let paths as [String]:
            return paths.compactMap(url)
        case let paths as [NSString]:
            return paths.compactMap { url(from: $0 as String) }
        case let array as NSArray:
            return array.compactMap {
                if let url = $0 as? URL { return url }
                if let url = $0 as? NSURL { return url as URL }
                if let string = $0 as? String { return url(from: string) }
                if let string = $0 as? NSString { return url(from: string as String) }
                return nil
            }
        case let data as Data:
            if let url = URL(dataRepresentation: data, relativeTo: nil) {
                return [url]
            }
            if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
               let paths = plist as? [String] {
                return paths.compactMap(url)
            }
            return []
        case let string as String:
            return url(from: string).map { [$0] } ?? []
        case let string as NSString:
            return url(from: string as String).map { [$0] } ?? []
        default:
            return []
        }
    }
}

/// Draft state for the in-shelf snippet editor. `id` nil = creating a new one.
struct SnippetDraft {
    var id: UUID?
    var trigger: String = ""
    var replacement: String = ""
}

/// What the pills above the thumbnails filter by: everything, a content type,
/// or a specific folder.
enum ShelfSelection: Hashable {
    case all, text, images, files, colors, snippets, notes
    case drive, gmail, calendar
    case folder(UUID)

    var title: String {
        switch self {
        case .all: return "All"
        case .text: return "Text"
        case .images: return "Images"
        case .files: return "Files"
        case .colors: return "Colors"
        case .snippets: return "Snippets"
        case .notes: return "Notes"
        case .drive: return "Drive"
        case .gmail: return "Mail"
        case .calendar: return "Calendar"
        case .folder: return ""   // folder pills render with the folder's name
        }
    }

    /// Remote (API-backed) tabs, not backed by local shelf items.
    var isRemote: Bool {
        switch self {
        case .drive, .gmail, .calendar: return true
        default: return false
        }
    }

    func matches(_ item: ShelfItem) -> Bool {
        switch self {
        case .all: return true
        case .text: return item.payload.kind == .text
        case .images: return item.payload.kind == .image
        case .files: return item.payload.kind == .file
        case .colors: return item.payload.kind == .color
        case .snippets: return item.payload.kind == .snippet
        case .notes: return item.payload.kind == .note
        case .drive, .gmail, .calendar: return false   // remote, not local items
        case .folder(let id): return item.folderId == id
        }
    }
}

private struct FilterPill: View {
    let title: String
    var systemImage: String? = nil
    var nsImage: NSImage? = nil
    var count: Int? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let nsImage {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 12, height: 12)
                        .clipShape(Circle())
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Color.white.opacity(0.82) : Color.white.opacity(0.38))
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(isSelected ? Color.white.opacity(0.28) : Color.white.opacity(0.10))
            )
        }
        .buttonStyle(.plain)
    }
}

/// Accepted drop types for the shelf (internal reorder marker + external content).
let shelfDropTypes: [UTType] = [
    NotchView.itemType, .fileURL, .image, .png, .tiff, .text, .plainText, .url, .html,
]

/// External content accepted by the compact import panel.
let importDropTypes: [UTType] = [
    .fileURL, .image, .png, .tiff, .text, .plainText, .url, .html,
]

let widgetDropTypes: [UTType] = [
    NotchView.widgetType,
]

struct WidgetMidXKey: PreferenceKey {
    static var defaultValue: [WidgetKind: CGFloat] = [:]
    static func reduce(value: inout [WidgetKind: CGFloat], nextValue: () -> [WidgetKind: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// Holds the widget kind being dragged. A reference type so it can be set in
/// `onDrag` WITHOUT a SwiftUI re-render (which would break the drop target).
final class WidgetDragState {
    var kind: WidgetKind?
}

struct WidgetBarDropDelegate: DropDelegate {
    let settings: PersistentBarSettings
    let widgets: [WidgetKind]
    let tileMidX: [WidgetKind: CGFloat]
    let dragState: WidgetDragState
    @Binding var insertionIndex: Int?

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            update(info)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated {
            update(info)
            return DropProposal(operation: dragState.kind == nil ? .copy : .move)
        }
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated {
            clear()
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            let target = insertionIndex ?? index(for: info.location.x)
            if let draggedKind = dragState.kind {
                settings.insertWidget(draggedKind, at: target)
                clear()
                return true
            }

            guard let provider = info.itemProviders(for: widgetDropTypes).first else {
                clear()
                return false
            }
            provider.loadDataRepresentation(forTypeIdentifier: NotchView.widgetType.identifier) { data, _ in
                guard let data,
                      let rawValue = String(data: data, encoding: .utf8),
                      let kind = WidgetKind(rawValue: rawValue) else { return }
                Task { @MainActor in
                    settings.insertWidget(kind, at: target)
                }
            }
            clear()
            return true
        }
    }

    private func update(_ info: DropInfo) {
        insertionIndex = index(for: info.location.x)
    }

    private func index(for x: CGFloat) -> Int {
        widgets.firstIndex {
            (tileMidX[$0] ?? .greatestFiniteMagnitude) > x
        } ?? widgets.count
    }

    private func clear() {
        dragState.kind = nil
        insertionIndex = nil
    }
}

/// One drop target for the entire import panel. It keeps the panel stable while
/// computing whether the cursor is specifically over the dashed import zone.
struct ImportPanelDropDelegate: DropDelegate {
    let dropZoneRect: CGRect
    @Binding var isPanelTargeted: Bool
    @Binding var isDropZoneTargeted: Bool
    let onPresent: () -> Void
    let onScheduleClose: () -> Void
    let onPerformDrop: ([NSItemProvider]) -> Bool

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            update(info)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated {
            update(info)
            return DropProposal(operation: .copy)
        }
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated {
            isPanelTargeted = false
            isDropZoneTargeted = false
            onScheduleClose()
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            isPanelTargeted = false
            isDropZoneTargeted = false
            return onPerformDrop(info.itemProviders(for: importDropTypes))
        }
    }

    private func update(_ info: DropInfo) {
        isPanelTargeted = true
        isDropZoneTargeted = dropZoneRect.insetBy(dx: -3, dy: -3).contains(info.location)
        onPresent()
    }
}

/// Collects each tile's horizontal midpoint (in the shelf coordinate space) so
/// the drop delegate can compute an insertion point from the cursor's x.
struct TileMidXKey: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] = [:]
    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// Single drop target for the whole panel. Reorders internal tile drags (using
/// the cursor's x against the tile midpoints) and routes external content to
/// the add handler. Using one target avoids unreliable per-tile drop targets
/// inside the ScrollView.
struct ShelfDropDelegate: DropDelegate {
    let store: ShelfStore
    let reorder: ReorderState
    let orderedIds: [UUID]
    let tileMidX: [UUID: CGFloat]
    @Binding var dropTargetId: UUID?
    @Binding var dropAtEnd: Bool
    @Binding var isDropTargeted: Bool
    let onPanelHover: (Bool) -> Void
    let onExternalDrop: ([NSItemProvider]) -> Bool

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            onPanelHover(true)
            update(info)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated {
            update(info)
            return DropProposal(operation: reorder.draggedId != nil ? .move : .copy)
        }
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated {
            onPanelHover(false)
            clear()
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            defer {
                clear()
                // Keep the panel open after the drop — the cursor is still over
                // it; it collapses normally once the mouse actually leaves.
                onPanelHover(true)
            }
            if let dragged = reorder.draggedId {
                if let target = dropTargetId {
                    store.reorder(dragged, before: target)
                } else {
                    store.moveToEnd(dragged)
                }
                store.commitReorder()
                reorder.draggedId = nil
                return true
            }
            return onExternalDrop(info.itemProviders(for: shelfDropTypes))
        }
    }

    private func update(_ info: DropInfo) {
        // Never show the accent border — it lingered after reorder drops.
        isDropTargeted = false
        guard reorder.draggedId != nil else {
            dropTargetId = nil
            dropAtEnd = false
            return
        }
        let x = info.location.x
        if let target = orderedIds.first(where: { (tileMidX[$0] ?? .greatestFiniteMagnitude) > x }) {
            dropTargetId = target
            dropAtEnd = false
        } else {
            dropTargetId = nil
            dropAtEnd = true
        }
    }

    private func clear() {
        isDropTargeted = false
        dropTargetId = nil
        dropAtEnd = false
    }
}

/// A horizontal "unroll" transition: the view scales on its x-axis from the
/// trailing edge (so it appears to slide out from the notch toward the left)
/// while fading. Height stays constant for a clean horizontal reveal.
private struct NotchRevealModifier: ViewModifier, Animatable {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: max(0.001, progress), anchor: .trailing)
            .opacity(progress)
    }
}

extension AnyTransition {
    static var notchReveal: AnyTransition {
        .modifier(
            active: NotchRevealModifier(progress: 0),
            identity: NotchRevealModifier(progress: 1)
        )
    }
}

/// Measures the meeting tab's intrinsic width so its right edge can be tucked
/// under the bar.
struct MeetingTabWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 90
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Text with a bright highlight sweeping across it (shimmer / loading effect).
struct ShimmerText: View {
    let text: String
    var font: Font = .system(size: 11, weight: .semibold)
    @State private var animate = false

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(.white.opacity(0.35))
            .overlay {
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.white.opacity(0), .white.opacity(0.95), .white.opacity(0)],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: geo.size.width)
                    .offset(x: animate ? geo.size.width : -geo.size.width)
                }
                .mask(Text(text).font(font))
            }
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    animate = true
                }
            }
    }
}

/// The four tabs of the expanded shelf.
enum ShelfTab: String, CaseIterable, Identifiable {
    case dash, assets, notes, snippets, colors
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dash: return "Dash"
        case .assets: return "Assets"
        case .notes: return "Notes"
        case .snippets: return "Snippets"
        case .colors: return "Colors"
        }
    }
}

/// A frosted, behind-window blur of whatever is behind the panel.
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    /// `.behindWindow` blurs the desktop (panel backdrop); `.withinWindow` blurs
    /// the shelf content drawn behind the view (frosted items/pills).
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = false
        // Force the frosted material dark so a black tint reads as black, not gray.
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}

/// Frosted item/pill background: blurs the shelf content behind it (within-window)
/// + 50% black, rounded — so it blends with the shelf's gradient/backdrop.
struct FrostedBackground: View {
    var cornerRadius: CGFloat = 14
    var body: some View {
        // SwiftUI Material (NOT an NSVisualEffectView): composited by SwiftUI so it
        // stays glued to its content inside ScrollViews. An NSViewRepresentable
        // blur here gets mispositioned in a scroll row, desyncing the visible card
        // from the SwiftUI hit-testing and making tiles steal each other's hover.
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.black.opacity(0.3))
            )
            .environment(\.colorScheme, .dark)
    }
}

/// Tab icons loaded from Resources (<tab>.svg), as template images for tinting.
enum TabIcons {
    private static let cache: [String: NSImage] = {
        var result: [String: NSImage] = [:]
        for name in ShelfTab.allCases.map(\.rawValue) {
            if let url = Bundle.main.url(forResource: name, withExtension: "svg"),
               let image = NSImage(contentsOf: url) {
                image.isTemplate = true
                result[name] = image
            }
        }
        return result
    }()

    static func icon(_ tab: ShelfTab) -> NSImage? { cache[tab.rawValue] }
}

/// Measures the audio controller card's height so the dash calendar can fill it.
struct AudioCardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 96
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Applies an explicit width when provided, otherwise fills the available width.
/// An explicit `.frame(width:)` is needed so the shelf can shrink below the tab
/// bar's intrinsic width; `.frame(maxWidth:)` alone would never go below it.
struct ShelfWidthModifier: ViewModifier {
    let width: CGFloat?
    func body(content: Content) -> some View {
        if let width {
            content.frame(width: width, alignment: .topLeading)
        } else {
            content.frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}
