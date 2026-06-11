import AppKit
import SwiftUI

/// A reusable AppKit-backed single-line text field (reliable focus in the
/// non-activating panel, like SearchField but generic).
struct PlainTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var shouldFocus: Bool = false
    var onBeginEditing: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.textColor = .white
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.lineBreakMode = .byTruncatingTail
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.35),
                .font: NSFont.systemFont(ofSize: 12),
            ]
        )
        field.stringValue = text
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text { nsView.stringValue = text }
        if shouldFocus, !context.coordinator.didFocus, let window = nsView.window {
            context.coordinator.didFocus = true
            DispatchQueue.main.async { window.makeFirstResponder(nsView) }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PlainTextField
        var didFocus = false

        init(_ parent: PlainTextField) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.onBeginEditing()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
    }
}
