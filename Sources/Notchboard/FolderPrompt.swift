import AppKit

/// Ask the user to name a new folder via a modal alert. Returns the trimmed
/// name, or nil if cancelled / left empty.
///
/// We use an NSAlert because the notch panel is a non-activating window that
/// can't become key, so an inline SwiftUI TextField wouldn't receive keystrokes.
@MainActor
func promptForFolderName(
    title: String = "New folder",
    confirmTitle: String = "Create",
    initial: String = ""
) -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = "Name your folder."
    alert.addButton(withTitle: confirmTitle)
    alert.addButton(withTitle: "Cancel")

    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
    field.placeholderString = "Folder name"
    field.stringValue = initial
    alert.accessoryView = field
    alert.window.initialFirstResponder = field

    // The accessory app must come forward so the alert can take keyboard focus.
    NSApp.activate(ignoringOtherApps: true)

    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? nil : name
}

/// Folder content types offered at creation, mapped to a payload kind for ordering.
let folderKindOptions: [(label: String, kind: ShelfPayload.Kind)] = [
    ("Text / URL", .text),
    ("Images", .image),
    ("Files / Video", .file),
    ("Notes", .note),
]

/// Ask for a new folder's name AND content type. Returns nil if cancelled.
@MainActor
func promptForNewFolder() -> (name: String, kind: ShelfPayload.Kind)? {
    let alert = NSAlert()
    alert.messageText = "New folder"
    alert.informativeText = "Name your folder and pick what it holds."
    alert.addButton(withTitle: "Create")
    alert.addButton(withTitle: "Cancel")

    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    field.placeholderString = "Folder name"

    let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26))
    popup.addItems(withTitles: folderKindOptions.map(\.label))

    let stack = NSStackView(views: [field, popup])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.frame = NSRect(x: 0, y: 0, width: 240, height: 62)
    alert.accessoryView = stack
    alert.window.initialFirstResponder = field

    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return nil }
    let kind = folderKindOptions[max(0, popup.indexOfSelectedItem)].kind
    return (name, kind)
}
