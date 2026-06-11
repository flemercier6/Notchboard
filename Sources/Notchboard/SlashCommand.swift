import SwiftUI

/// A Notion-style block command available from the note editor's "/" menu.
enum SlashCommand: String, CaseIterable, Identifiable {
    case h1, h2, h3, bulletList, numberedList, divider

    var id: String { rawValue }

    var title: String {
        switch self {
        case .h1: return "Heading 1"
        case .h2: return "Heading 2"
        case .h3: return "Heading 3"
        case .bulletList: return "Bullet list"
        case .numberedList: return "Numbered list"
        case .divider: return "Divider"
        }
    }

    var systemImage: String {
        switch self {
        case .h1: return "textformat.size.larger"
        case .h2: return "textformat.size"
        case .h3: return "textformat.size.smaller"
        case .bulletList: return "list.bullet"
        case .numberedList: return "list.number"
        case .divider: return "minus"
        }
    }

    /// Words that match this command when typing after "/".
    var keywords: [String] {
        switch self {
        case .h1: return ["h1", "heading1", "title", "heading"]
        case .h2: return ["h2", "heading2", "subtitle", "heading"]
        case .h3: return ["h3", "heading3", "heading"]
        case .bulletList: return ["bullet", "list", "ul", "unordered"]
        case .numberedList: return ["numbered", "number", "ol", "ordered", "list"]
        case .divider: return ["divider", "hr", "rule", "separator", "line"]
        }
    }

    /// The markdown the current line becomes when the command is applied.
    var replacement: String {
        switch self {
        case .h1: return "# "
        case .h2: return "## "
        case .h3: return "### "
        case .bulletList: return "- "
        case .numberedList: return "1. "
        case .divider: return "---\n"
        }
    }

    static func matching(_ query: String) -> [SlashCommand] {
        guard !query.isEmpty else { return allCases }
        let q = query.lowercased()
        return allCases.filter { cmd in
            cmd.rawValue.lowercased().hasPrefix(q) || cmd.keywords.contains { $0.hasPrefix(q) }
        }
    }
}

/// Shared state driving the slash-command dropdown. The note editor updates it
/// while typing; the SwiftUI overlay reads it and can apply a command via `apply`.
@MainActor
final class SlashController: ObservableObject {
    @Published var active = false
    @Published var query = ""
    @Published var highlight = 0

    /// Set by the editor's coordinator; mutates the text view to apply a command.
    var apply: ((SlashCommand) -> Void)?

    var matches: [SlashCommand] { SlashCommand.matching(query) }

    func reset() {
        active = false
        query = ""
        highlight = 0
    }
}
