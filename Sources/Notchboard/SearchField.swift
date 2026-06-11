import AppKit
import SwiftUI

/// An AppKit-backed search input. Using NSTextField directly (instead of a
/// SwiftUI TextField + @FocusState) lets us grab first responder reliably the
/// moment the field appears — which also makes the non-activating panel become
/// key — so a shortcut-opened search is immediately typable with no click.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var onCancel: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = .white
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.lineBreakMode = .byTruncatingTail
        field.placeholderAttributedString = NSAttributedString(
            string: "Search",
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.4),
                .font: NSFont.systemFont(ofSize: 13),
            ]
        )
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        // Focus as soon as the field is in a window. Making a text field the
        // first responder also pulls key status to the panel.
        if context.coordinator.needsFocus, let window = nsView.window {
            context.coordinator.needsFocus = false
            DispatchQueue.main.async {
                window.makeFirstResponder(nsView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField
        var needsFocus = true

        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()   // Escape closes search
                return true
            }
            return false
        }
    }
}
