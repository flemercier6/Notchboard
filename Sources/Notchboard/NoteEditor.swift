import AppKit
import CoreText
import SwiftUI

/// A multi-line, AppKit-backed text editor for notes (markdown source). Backed
/// by NSTextView so it grabs first responder reliably in the non-activating
/// panel and supports multi-line editing with scrolling.
///
/// It renders markdown *live* (Notion-style) while keeping the underlying source
/// intact for storage:
///   • headings (`# `, `## `, `### `) get a large bold font and the `#` markers
///     are hidden entirely (zero-width glyphs);
///   • bullet lines (`- `) draw a real `•` instead of the dash;
///   • a `---` line is hidden and drawn as a full-width horizontal rule.
///
/// It also powers a "/" command menu: typing "/" at the start of a line activates
/// `slash`; Enter / arrows / Esc are intercepted, and selecting a command
/// rewrites the current line as markdown.
struct NoteEditor: NSViewRepresentable {
    @Binding var text: String
    var slash: SlashController
    var shouldFocus: Bool = false
    var onBeginEditing: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        // Build a TextKit 1 stack so we can hook glyph generation (to hide
        // markers / swap the bullet) and draw the divider rule.
        let textStorage = NSTextStorage()
        let layoutManager = MarkdownLayoutManager()
        layoutManager.delegate = context.coordinator.glyphHider
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let textView: NSTextView = NSTextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .white
        textView.insertionPointColor = .white
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.usesFontPanel = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scroll.documentView = textView
        context.coordinator.textView = textView
        textView.string = text
        context.coordinator.applyStyling(textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.textView = textView
        if textView.string != text {
            textView.string = text
            context.coordinator.applyStyling(textView)
        }
        if shouldFocus, !context.coordinator.didFocus, let window = textView.window {
            context.coordinator.didFocus = true
            DispatchQueue.main.async { window.makeFirstResponder(textView) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteEditor
        weak var textView: NSTextView?
        var didFocus = false
        /// Non-isolated helper that hides markers / swaps the bullet glyph. Kept
        /// separate so it can act as the (nonisolated) layout-manager delegate.
        let glyphHider = GlyphHider()

        init(_ parent: NoteEditor) {
            self.parent = parent
            super.init()
            parent.slash.apply = { [weak self] command in self?.apply(command) }
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onBeginEditing()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            self.textView = textView
            parent.text = textView.string
            parent.slash.apply = { [weak self] command in self?.apply(command) }
            applyStyling(textView)
            updateSlash(textView)
        }

        /// Live markdown styling: heading fonts + divider color, and refresh the
        /// marker sets the glyph hider reads.
        func applyStyling(_ textView: NSTextView) {
            recomputeMarkers(textView)
            guard let storage = textView.textStorage else { return }
            let ns = storage.string as NSString
            let full = NSRange(location: 0, length: ns.length)

            storage.beginEditing()
            storage.setAttributes(
                [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white],
                range: full
            )
            ns.enumerateSubstrings(in: full, options: .byLines) { sub, lineRange, _, _ in
                guard let line = sub else { return }
                let level = headingLevel(line)
                if level > 0 {
                    let size: CGFloat = level == 1 ? 22 : (level == 2 ? 18 : 15)
                    storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: size), range: lineRange)
                } else if line == "---" {
                    // Hide the dashes; the layout manager draws a rule in their place.
                    storage.addAttribute(.foregroundColor, value: NSColor.clear, range: lineRange)
                }
            }
            storage.endEditing()

            // Force glyph regeneration so hidden markers / bullets update.
            textView.layoutManager?.invalidateGlyphs(
                forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil
            )
        }

        /// Recompute which character indexes are hidden heading markers and which
        /// dashes should render as bullets, then hand them to the glyph hider.
        private func recomputeMarkers(_ textView: NSTextView) {
            let ns = textView.string as NSString
            let full = NSRange(location: 0, length: ns.length)
            var hidden = Set<Int>()
            var bullets = Set<Int>()
            ns.enumerateSubstrings(in: full, options: .byLines) { sub, lineRange, _, _ in
                guard let line = sub else { return }
                let level = headingLevel(line)
                if level > 0 {
                    // Hide "# " (2), "## " (3) or "### " (4) — marker + trailing space.
                    for k in 0..<(level + 1) { hidden.insert(lineRange.location + k) }
                } else if line.hasPrefix("- ") {
                    bullets.insert(lineRange.location)   // the dash becomes "•"
                }
            }
            glyphHider.hidden = hidden
            glyphHider.bulletDashes = bullets
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            updateSlash(textView)
        }

        // Intercept keys while the slash menu is open.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard parent.slash.active else { return false }
            let matches = parent.slash.matches
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if !matches.isEmpty {
                    apply(matches[min(parent.slash.highlight, matches.count - 1)])
                }
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.slash.highlight = min(parent.slash.highlight + 1, max(0, matches.count - 1))
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.slash.highlight = max(parent.slash.highlight - 1, 0)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.slash.reset()
                return true
            default:
                return false
            }
        }

        /// Detect "/query" from the line start up to the caret.
        private func updateSlash(_ textView: NSTextView) {
            let ns = textView.string as NSString
            let caret = min(textView.selectedRange().location, ns.length)
            let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
            let prefixLength = caret - lineRange.location
            guard prefixLength > 0 else { parent.slash.reset(); return }
            let linePrefix = ns.substring(with: NSRange(location: lineRange.location, length: prefixLength))

            if linePrefix.first == "/" {
                let query = String(linePrefix.dropFirst())
                if query.allSatisfy({ $0.isLetter || $0.isNumber }) {
                    parent.slash.query = query
                    if !parent.slash.active { parent.slash.highlight = 0 }
                    parent.slash.highlight = min(parent.slash.highlight, max(0, parent.slash.matches.count - 1))
                    parent.slash.active = true
                    return
                }
            }
            if parent.slash.active { parent.slash.reset() }
        }

        /// Replace the current "/..." line with the command's markdown.
        private func apply(_ command: SlashCommand) {
            guard let textView else { return }
            let ns = textView.string as NSString
            let caret = min(textView.selectedRange().location, ns.length)
            let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
            var replaceRange = lineRange
            if ns.substring(with: lineRange).hasSuffix("\n") {
                replaceRange.length -= 1
            }
            let replacement = command.replacement
            if textView.shouldChangeText(in: replaceRange, replacementString: replacement) {
                textView.replaceCharacters(in: replaceRange, with: replacement)
                textView.didChangeText()
                let caretLocation = replaceRange.location + (replacement as NSString).length
                textView.setSelectedRange(NSRange(location: caretLocation, length: 0))
            }
            parent.text = textView.string
            applyStyling(textView)
            parent.slash.reset()
        }
    }
}

/// `0` for non-headings, else the heading level (1–3).
private func headingLevel(_ line: String) -> Int {
    if line.hasPrefix("### ") { return 3 }
    if line.hasPrefix("## ") { return 2 }
    if line.hasPrefix("# ") { return 1 }
    return 0
}

/// Layout manager that draws a full-width horizontal rule wherever a line is
/// exactly "---" (the dashes themselves are made transparent by the styler).
final class MarkdownLayoutManager: NSLayoutManager {
    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let ns = storage.string as NSString
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        ns.enumerateSubstrings(in: charRange, options: .byLines) { sub, subRange, _, _ in
            guard sub == "---" else { return }
            let gRange = self.glyphRange(forCharacterRange: subRange, actualCharacterRange: nil)
            guard gRange.length > 0 else { return }
            let frag = self.lineFragmentRect(forGlyphAt: gRange.location, effectiveRange: nil)
            let y = (origin.y + frag.midY).rounded() + 0.5
            let inset: CGFloat = 6
            let path = NSBezierPath()
            path.lineWidth = 1
            path.move(to: NSPoint(x: origin.x + inset, y: y))
            path.line(to: NSPoint(x: origin.x + container.size.width - inset, y: y))
            NSColor.white.withAlphaComponent(0.25).setStroke()
            path.stroke()
        }
    }
}

/// Hides heading markers and swaps the bullet dash for a real "•" during glyph
/// generation. Plain (non-isolated) NSObject so it can be a layout-manager
/// delegate; only touched on the main thread.
final class GlyphHider: NSObject, NSLayoutManagerDelegate {
    var hidden = Set<Int>()
    var bulletDashes = Set<Int>()

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes charIndexes: UnsafePointer<Int>,
        font aFont: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        let count = glyphRange.length
        guard count > 0, !(hidden.isEmpty && bulletDashes.isEmpty) else { return 0 }

        var newProps = Array(UnsafeBufferPointer(start: props, count: count))
        var newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: count))
        var modified = false
        var bulletGlyph: CGGlyph = 0

        for i in 0..<count {
            let ci = charIndexes[i]
            if hidden.contains(ci) {
                newProps[i] = .null
                modified = true
            } else if bulletDashes.contains(ci) {
                if bulletGlyph == 0 { bulletGlyph = Self.glyph(for: "•", font: aFont) }
                newGlyphs[i] = bulletGlyph
                modified = true
            }
        }
        guard modified else { return 0 }

        layoutManager.setGlyphs(
            &newGlyphs, properties: &newProps,
            characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange
        )
        return count
    }

    static func glyph(for string: String, font: NSFont) -> CGGlyph {
        var chars = Array(string.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        CTFontGetGlyphsForCharacters(font as CTFont, &chars, &glyphs, chars.count)
        return glyphs.first ?? 0
    }
}
