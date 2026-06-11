import AppKit
import SwiftUI
import Combine

/// Borderless, non-activating panel anchored at the top-center of the notched
/// display. The window is a FIXED size (always the expanded footprint) so it
/// never resizes — that's what keeps hover detection from flickering. Only the
/// SwiftUI content collapses/expands inside it. Transparent areas pass clicks
/// through to whatever is underneath.
@MainActor
final class NotchWindow: NSPanel {
    private let store: ShelfStore
    private let driveAuth: GoogleDriveAuth
    private let driveService: GoogleDriveService
    private let gmailService: GmailService
    private let calendarService: GoogleCalendarService
    private let gmailNotifier: GmailNotifier
    private let meeting: MeetingController
    private let nowPlaying: NowPlayingService
    private let appleCalendar: AppleCalendarService
    private let slack: SlackService
    private let notionAuth: NotionAuth
    private let notionService: NotionService
    let viewModel = NotchViewModel()
    private var cancellables = Set<AnyCancellable>()

    // Expanded footprint.
    // Upper bound on the panel height; the SwiftUI content sizes itself within
    // this and any leftover space below the panel stays transparent.
    private let bodyHeight: CGFloat = 520
    private let widthRatio: CGFloat = 0.45   // baseline footprint = 45% of the screen
    // The panel must be wide enough to hold the widest shelf state — the Dash with
    // all sections visible. The SwiftUI content still sizes itself (narrower,
    // centered under the notch); the extra width stays transparent and passes
    // clicks through. Keep in sync with NotchView.availableShelfWidth.
    private let minExpandedWidth: CGFloat = 980

    init(
        store: ShelfStore,
        driveAuth: GoogleDriveAuth,
        driveService: GoogleDriveService,
        gmailService: GmailService,
        calendarService: GoogleCalendarService,
        gmailNotifier: GmailNotifier,
        meeting: MeetingController,
        nowPlaying: NowPlayingService,
        appleCalendar: AppleCalendarService,
        slack: SlackService,
        notionAuth: NotionAuth,
        notionService: NotionService
    ) {
        self.store = store
        self.driveAuth = driveAuth
        self.driveService = driveService
        self.gmailService = gmailService
        self.calendarService = calendarService
        self.gmailNotifier = gmailNotifier
        self.meeting = meeting
        self.nowPlaying = nowPlaying
        self.appleCalendar = appleCalendar
        self.slack = slack
        self.notionAuth = notionAuth
        self.notionService = notionService
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        // No window shadow — its halo around the notch shape reads as a border
        // around both the compact bar and the expanded shelf.
        hasShadow = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        // Only grab key focus when a control needs it (the search field) — so
        // buttons, tiles and drag-out never steal focus from the foreground app.
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let hosting = NSHostingView(rootView: NotchView(
            store: store,
            viewModel: viewModel,
            driveAuth: driveAuth,
            driveService: driveService,
            gmailService: gmailService,
            calendarService: calendarService,
            gmailNotifier: gmailNotifier,
            meeting: meeting,
            nowPlaying: nowPlaying,
            appleCalendar: appleCalendar,
            slack: slack,
            notionAuth: notionAuth,
            notionService: notionService
        ))
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting

        // Text input (search field, or editing a color's hex) needs the panel
        // to be key and the app active; release focus when neither is active.
        viewModel.$isSearching
            .combineLatest(viewModel.$editingColorId, viewModel.$isEditingSnippet, viewModel.$isEditingNote)
            .map { searching, editingColor, editingSnippet, editingNote in
                searching || editingColor != nil || editingSnippet || editingNote
            }
            .removeDuplicates()
            .sink { [weak self] needsKeyboard in
                guard let self else { return }
                if needsKeyboard {
                    NSApp.activate(ignoringOtherApps: true)
                    self.makeKeyAndOrderFront(nil)
                } else if self.isKeyWindow {
                    // Give focus back to the previously-active app.
                    NSApp.deactivate()
                }
            }
            .store(in: &cancellables)
    }

    // Allow key status (needed for the search field), but only when requested
    // via becomesKeyOnlyIfNeeded.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Clicking outside the panel makes it resign key — close the search (which
    // collapses the panel unless it's still hovered).
    override func resignKey() {
        super.resignKey()
        // Clicking outside stops color editing, and dismisses the panel if it
        // was a search.
        viewModel.editingColorId = nil
        if viewModel.isSearching {
            viewModel.dismiss()
        }
    }

    // AppKit normally pushes windows down so they don't overlap the menu bar.
    // We want to be glued to the very top of the screen (top: 0), flush against
    // the notch — so we opt out of that constraint and keep our frame as-is.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    func placeAtNotch() {
        let metrics = NotchMetrics.current()
        let width = min(metrics.screenFrame.width,
                        max(metrics.screenFrame.width * widthRatio, minExpandedWidth))
        let height = metrics.notchHeight + bodyHeight
        let frame = CGRect(
            x: metrics.screenFrame.midX - width / 2,
            y: metrics.screenFrame.maxY - height,
            width: width,
            height: height
        )
        setFrame(frame, display: true)
    }
}
