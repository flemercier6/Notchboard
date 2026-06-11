import AppKit
import ApplicationServices

/// Watches global keystrokes; when the user types a snippet trigger, deletes it
/// and types the replacement. Requires Input Monitoring (to observe keys) AND
/// Accessibility (to post the synthesized keystrokes) permissions.
@MainActor
final class SnippetExpander {
    var snippets: [(trigger: String, replacement: String)] = []

    private var monitor: Any?
    private var buffer = ""
    private let maxBuffer = 64

    // Tags our own synthesized events so they don't feed back into the monitor.
    private let marker: Int64 = 0x4E4F5443  // "NOTC"
    private var isExpanding = false

    func start() {
        guard monitor == nil else { return }
        // Prompt for Accessibility — required to post the replacement keystrokes.
        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        log("start: AX trusted=\(trusted)")
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        log("monitor installed=\(monitor != nil)")
    }

    // MARK: - Debug logging (to /tmp/notchboard-snippets.log)
    private func log(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        let url = URL(fileURLWithPath: "/tmp/notchboard-snippets.log")
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    private func handle(_ event: NSEvent) {
        // Ignore our own synthesized keystrokes (and anything while expanding).
        if isExpanding { return }
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == marker { return }

        // Modifier combos are shortcuts, not typing.
        let mods = event.modifierFlags
        if mods.contains(.command) || mods.contains(.control) || mods.contains(.option) {
            buffer = ""
            return
        }

        switch event.keyCode {
        case 51, 117:                              // delete / forward-delete
            if !buffer.isEmpty { buffer.removeLast() }
            return
        case 36, 76, 48, 53, 123, 124, 125, 126:   // return, enter, tab, esc, arrows
            buffer = ""
            return
        default:
            break
        }

        guard let chars = event.characters, !chars.isEmpty else { return }
        if chars.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) {
            buffer = ""
            return
        }

        buffer += chars
        if buffer.count > maxBuffer { buffer = String(buffer.suffix(maxBuffer)) }
        log("key=\(chars) buffer=\(buffer) snippets=\(snippets.map(\.trigger))")

        for snippet in snippets where !snippet.trigger.isEmpty {
            if buffer.hasSuffix(snippet.trigger) {
                buffer = ""
                log("MATCH trigger=\(snippet.trigger) → expanding")
                expand(trigger: snippet.trigger, replacement: snippet.replacement)
                return
            }
        }
    }

    private func expand(trigger: String, replacement: String) {
        isExpanding = true
        let source = CGEventSource(stateID: .combinedSessionState)

        // Remove the just-typed trigger.
        for _ in 0..<trigger.count {
            post(key: 51, source: source)   // 51 = delete (backspace)
        }

        // Type the replacement as a unicode string.
        let utf16 = Array(replacement.utf16)
        if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
           let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            down.setIntegerValueField(.eventSourceUserData, value: marker)
            up.setIntegerValueField(.eventSourceUserData, value: marker)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }

        // Stop ignoring once the synthesized events have drained.
        DispatchQueue.main.async { [weak self] in self?.isExpanding = false }
    }

    private func post(key: CGKeyCode, source: CGEventSource?) {
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.setIntegerValueField(.eventSourceUserData, value: marker)
        up?.setIntegerValueField(.eventSourceUserData, value: marker)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
