import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ShelfStore()
    private let driveAuth = GoogleDriveAuth()
    private lazy var driveService = GoogleDriveService(auth: driveAuth)
    private lazy var gmailService = GmailService(auth: driveAuth)
    private lazy var calendarService = GoogleCalendarService(auth: driveAuth)
    private lazy var gmailNotifier = GmailNotifier(auth: driveAuth)
    private let meetingDetector = MeetingDetector()
    private lazy var meetingController = MeetingController(detector: meetingDetector, store: store)
    private let nowPlaying = NowPlayingService()
    private let appleCalendar = AppleCalendarService()
    private let slack = SlackService()
    private let notionAuth = NotionAuth()
    private lazy var notionService = NotionService(auth: notionAuth)
    private let supabase = SupabaseManager()
    private lazy var syncService = SyncService(store: store, supabase: supabase)
    private lazy var authWindow = AuthWindowController(supabase: supabase, sync: syncService)
    private var window: NotchWindow?

    private let expander = SnippetExpander()
    private var cancellables = Set<AnyCancellable>()

    private var flagsMonitor: Any?
    private var keyMonitor: Any?
    private var localMonitor: Any?

    // Double-tap ⌘ detection.
    private var commandWasDown = false
    private var tapValid = false              // current press is a clean ⌘-only tap
    private var otherKeyWhileCommand = false  // a key was pressed while ⌘ held
    private var lastCommandTapTime: TimeInterval = 0
    private let doubleTapWindow: TimeInterval = 0.4

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NotchWindow(
            store: store,
            driveAuth: driveAuth,
            driveService: driveService,
            gmailService: gmailService,
            calendarService: calendarService,
            gmailNotifier: gmailNotifier,
            meeting: meetingController,
            nowPlaying: nowPlaying,
            appleCalendar: appleCalendar,
            slack: slack,
            notionAuth: notionAuth,
            notionService: notionService,
            supabase: supabase,
            onOpenAuth: { [weak self] in self?.authWindow.show() }
        )
        window.placeAtNotch()
        window.orderFrontRegardless()
        self.window = window

        // Keep the panel glued to the notch when displays change (resolution,
        // external monitor plugged/unplugged, etc.).
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.window?.placeAtNotch()
            }
        }

        installShortcutMonitors()

        // Watch Gmail for new mail to flash the notification banner.
        gmailNotifier.start()

        // Watch for an active microphone (a meeting starting) to offer recording.
        meetingDetector.start()

        // Poll music players for now-playing info / transport controls.
        nowPlaying.start()

        // Request Apple Calendar access and load events for the dash.
        appleCalendar.start()

        // Connect Slack (Socket Mode) for real-time message notifications.
        slack.start()

        // Spin up the sync engine so it observes auth and syncs when enabled.
        _ = syncService

        // Feed the text-expansion engine the current snippets, keeping it in
        // sync as items change.
        expander.start()
        store.$items
            .sink { [weak expander] items in
                expander?.snippets = items.compactMap {
                    if case .snippet(let trigger, let replacement) = $0.payload {
                        return (trigger, replacement)
                    }
                    return nil
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Global double-tap ⌘ shortcut
    //
    // Opens the search panel when the user taps the Command key twice in quick
    // succession (with no other key in between). Global monitoring of keyboard
    // events requires Input Monitoring permission (System Settings › Privacy).

    private func installShortcutMonitors() {
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleFlags(event) }
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.otherKeyWhileCommand = true }
        }
        // A local monitor so the shortcut also works while our app is frontmost.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.type == .keyDown {
                    self?.otherKeyWhileCommand = true
                } else {
                    self?.handleFlags(event)
                }
            }
            return event
        }
    }

    private func handleFlags(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let commandDown = mods.contains(.command)

        if commandDown && !commandWasDown {
            // ⌘ just pressed — a clean tap needs ⌘ alone and no other key.
            commandWasDown = true
            tapValid = (mods == [.command])
            otherKeyWhileCommand = false
        } else if commandDown {
            // Another modifier joined while ⌘ is held → not a clean tap.
            if mods != [.command] { tapValid = false }
        } else if !commandDown && commandWasDown {
            // ⌘ released.
            commandWasDown = false
            guard tapValid && !otherKeyWhileCommand else {
                lastCommandTapTime = 0
                return
            }
            let now = event.timestamp
            if now - lastCommandTapTime < doubleTapWindow {
                lastCommandTapTime = 0
                openSearch()
            } else {
                lastCommandTapTime = now
            }
        }
    }

    private func openSearch() {
        // Compact (search-only) when the panel is currently collapsed.
        let compact = !(window?.viewModel.isExpanded ?? false)
        window?.viewModel.openSearch(compact: compact)
    }
}
