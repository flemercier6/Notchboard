import AppKit
import EventKit

/// Reads the user's Apple Calendar (EventKit) events so they can be merged with
/// Google Calendar in the dash. Per-event colour comes from its EKCalendar.
@MainActor
final class AppleCalendarService: ObservableObject {
    @Published private(set) var events: [CalendarEvent] = []

    private let store = EKEventStore()
    private var authorized = false

    func start() {
        store.requestFullAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.authorized = granted
                if granted { self?.reload() }
            }
        }
    }

    func reload() {
        guard authorized else { return }
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -45, to: Date()) ?? Date()
        let end = cal.date(byAdding: .day, value: 120, to: Date()) ?? Date()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = store.events(matching: predicate).map { event in
            CalendarEvent(
                id: event.eventIdentifier ?? UUID().uuidString,
                summary: event.title ?? "(no title)",
                start: event.startDate,
                end: event.endDate,
                isAllDay: event.isAllDay,
                htmlLink: nil,
                colorHex: Self.hex(from: event.calendar?.cgColor)
            )
        }
    }

    static func hex(from cgColor: CGColor?) -> String? {
        guard let cgColor,
              let converted = cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let comps = converted.components, comps.count >= 3 else { return nil }
        let r = Int((comps[0] * 255).rounded())
        let g = Int((comps[1] * 255).rounded())
        let b = Int((comps[2] * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
