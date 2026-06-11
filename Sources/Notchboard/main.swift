import AppKit

// Notchboard runs as a background accessory app: no Dock icon, no menu bar entry.
// Everything lives in a borderless panel anchored under the MacBook notch.
//
// Top-level code in main.swift is nonisolated, but the AppKit objects we touch
// are main-actor isolated — and the process entry point *is* the main thread,
// so we hop onto the main actor explicitly.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
