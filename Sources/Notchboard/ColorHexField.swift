import AppKit
import SwiftUI

/// An in-tile, editable hex code field for color items. AppKit-backed so it can
/// grab first responder reliably the moment a freshly-created swatch appears
/// (which also pulls key status to the non-activating panel).
struct ColorHexField: NSViewRepresentable {
    @Binding var hex: String
    var shouldFocus: Bool
    var onBeginEditing: () -> Void = {}
    var onCommit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 10, weight: .regular)
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.lineBreakMode = .byTruncatingTail
        field.stringValue = hex
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != hex { nsView.stringValue = hex }
        nsView.textColor = NSColor(Color.readableText(onHex: hex))

        if shouldFocus, !context.coordinator.didFocus, let window = nsView.window {
            context.coordinator.didFocus = true
            DispatchQueue.main.async {
                window.makeFirstResponder(nsView)
                nsView.currentEditor()?.selectedRange = NSRange(location: nsView.stringValue.count, length: 0)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ColorHexField
        var didFocus = false

        init(_ parent: ColorHexField) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) {
            // The user clicked into the field — make sure the panel takes
            // keyboard focus (and the app activates) so typing works.
            parent.onBeginEditing()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            var value = field.stringValue
            // Always keep a single leading "#".
            value = "#" + value.replacingOccurrences(of: "#", with: "")
            if field.stringValue != value { field.stringValue = value }
            parent.hex = value
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onCommit()
        }
    }
}
