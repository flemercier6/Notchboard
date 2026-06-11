import Foundation

/// Which integration a notification came from.
enum NotificationSource: String {
    case gmail, slack

    var label: String {
        switch self {
        case .gmail: return "Gmail"
        case .slack: return "Slack"
        }
    }
}

/// A unified notification item shown in the Dash "Notifications" section, fed by
/// the Gmail and Slack services.
struct AppNotification: Identifiable, Equatable {
    let id: String
    let source: NotificationSource
    /// Email sender display name, or Slack sender name.
    let sender: String
    /// One-line preview: the email subject, or the Slack message text.
    let preview: String
    /// Slack sender profile picture (nil for Gmail).
    let avatarURL: URL?
    let date: Date
}
