import Foundation

/// A single Calendar event.
struct CalendarEvent: Identifiable {
    let id: String
    let summary: String
    let start: Date?
    let end: Date?
    let isAllDay: Bool
    let htmlLink: String?
    /// The source calendar's colour ("#RRGGBB"), for the pastille.
    var colorHex: String? = nil

    /// "12:00 – 13:00", or "All day".
    var timeRange: String {
        guard !isAllDay, let start else { return "All day" }
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "HH:mm"
        if let end { return "\(f.string(from: start)) – \(f.string(from: end))" }
        return f.string(from: start)
    }

    /// Short human label for the tile, e.g. "Mon 9 Jun, 14:30" or "Mon 9 Jun".
    var dateLabel: String {
        guard let start else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = isAllDay ? "EEE d MMM" : "EEE d MMM, HH:mm"
        return formatter.string(from: start)
    }
}

private struct CalendarListResponse: Decodable {
    let items: [RawEvent]
}

private struct RawEvent: Decodable {
    let id: String
    let summary: String?
    let htmlLink: String?
    let start: When?
    let end: When?
    let colorId: String?

    struct When: Decodable {
        let dateTime: String?
        let date: String?
    }

    private static func parse(_ when: When?) -> (date: Date?, allDay: Bool) {
        if let dateTime = when?.dateTime {
            let d = ISO8601DateFormatter().date(from: dateTime)
                ?? ISO8601DateFormatter.withFractionalSeconds.date(from: dateTime)
            return (d, false)
        } else if let day = when?.date {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return (f.date(from: day), true)
        }
        return (nil, false)
    }

    func toEvent(colorMap: [String: String], defaultHex: String?) -> CalendarEvent {
        let (startDate, allDay) = Self.parse(start)
        let (endDate, _) = Self.parse(end)
        let color = colorId.flatMap { colorMap[$0] } ?? defaultHex
        return CalendarEvent(
            id: id,
            summary: (summary?.isEmpty == false ? summary! : "(no title)"),
            start: startDate,
            end: endDate,
            isAllDay: allDay,
            htmlLink: htmlLink,
            colorHex: color
        )
    }
}

private struct ColorsResponse: Decodable {
    struct Entry: Decodable { let background: String? }
    let event: [String: Entry]?
}

private struct PrimaryCalendar: Decodable {
    let backgroundColor: String?
}

private extension ISO8601DateFormatter {
    static let withFractionalSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// Lists upcoming events on the user's primary calendar and searches them.
/// Clicking a result opens it in the browser (handled by the view).
@MainActor
final class GoogleCalendarService: ObservableObject {
    @Published private(set) var events: [CalendarEvent] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    let auth: GoogleDriveAuth
    private var queryTask: Task<Void, Never>?
    private var colorMap: [String: String] = [:]
    private var primaryColorHex: String?
    private var colorsLoaded = false

    init(auth: GoogleDriveAuth) { self.auth = auth }

    /// Fetch (once) the colour palette + primary calendar colour for pastilles.
    private func ensureColors(token: String) async {
        guard !colorsLoaded else { return }
        colorsLoaded = true
        if let url = URL(string: "https://www.googleapis.com/calendar/v3/colors") {
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let decoded = try? JSONDecoder().decode(ColorsResponse.self, from: data) {
                colorMap = (decoded.event ?? [:]).compactMapValues { $0.background }
            }
        }
        if let url = URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList/primary") {
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let decoded = try? JSONDecoder().decode(PrimaryCalendar.self, from: data) {
                primaryColorHex = decoded.backgroundColor
            }
        }
    }

    func loadUpcoming() { run(searchText: nil) }

    func search(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        run(searchText: trimmed.isEmpty ? nil : trimmed)
    }

    private func run(searchText: String?) {
        queryTask?.cancel()
        queryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }

            isLoading = true
            defer { isLoading = false }
            do {
                let token = try await auth.accessToken()
                guard !Task.isCancelled else { return }
                await ensureColors(token: token)

                var comps = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
                let startOfToday = Calendar.current.startOfDay(for: Date())
                comps.queryItems = [
                    URLQueryItem(name: "timeMin", value: ISO8601DateFormatter().string(from: startOfToday)),
                    URLQueryItem(name: "maxResults", value: "50"),
                    URLQueryItem(name: "singleEvents", value: "true"),
                    URLQueryItem(name: "orderBy", value: "startTime"),
                    URLQueryItem(name: "q", value: searchText),
                ].filter { $0.value != nil }

                var req = URLRequest(url: comps.url!)
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                    if http.statusCode == 403 {
                        throw DriveError.message("Calendar access denied. Enable the Google Calendar API in Google Cloud Console and reconnect your account.")
                    }
                    throw DriveError.message("Calendar request failed (\(http.statusCode)).")
                }
                let list = try JSONDecoder().decode(CalendarListResponse.self, from: data)
                guard !Task.isCancelled else { return }

                events = list.items.map { $0.toEvent(colorMap: colorMap, defaultHex: primaryColorHex) }
                errorMessage = nil
            } catch is CancellationError {
                // Superseded by a newer query.
            } catch {
                errorMessage = (error as? DriveError)?.text ?? error.localizedDescription
            }
        }
    }
}
