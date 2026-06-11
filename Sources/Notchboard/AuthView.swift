import AppKit
import SwiftUI

/// Borderless, centered panel that hosts the sign-in popover. Subclassed so a
/// borderless window can still become key (needed for the text fields).
@MainActor
final class AuthPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Shows / hides the centered auth popover window.
@MainActor
final class AuthWindowController {
    private let supabase: SupabaseManager
    private let sync: SyncService
    private var window: AuthPanel?

    init(supabase: SupabaseManager, sync: SyncService) {
        self.supabase = supabase
        self.sync = sync
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.center()
            return
        }
        let panel = AuthPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 460),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hosting = NSHostingView(rootView: AuthView(
            supabase: supabase,
            sync: sync,
            onClose: { [weak self] in self?.close() }
        ))
        panel.contentView = hosting
        panel.center()
        window = panel

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }
}

/// The sign-in / sign-up popover content.
struct AuthView: View {
    @ObservedObject var supabase: SupabaseManager
    @ObservedObject var sync: SyncService
    var onClose: () -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var isSignUp = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Inner div: shelf-style background (gradient + frosted blur).
            .background(shelfStyleBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            // Outer container: 10px padding + blur + radius 20.
            .padding(10)
            .background(VisualEffectBlur())
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .frame(width: 320, height: 460)
            .overlay(alignment: .topTrailing) { closeButton.padding(18) }
            .environment(\.colorScheme, .dark)
            .onExitCommand { onClose() }
            .onChange(of: supabase.isSignedIn) { _, signedIn in
                if signedIn { onClose() }
            }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if supabase.isSignedIn {
            signedInContent
        } else {
            formContent
        }
    }

    private var formContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Notchboard")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                Text(isSignUp ? "Create an account to sync your shelf across devices."
                              : "Sign in to sync your shelf across devices.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                field(icon: "envelope", placeholder: "Email", text: $email, secure: false)
                field(icon: "lock", placeholder: "Password", text: $password, secure: true)
            }

            if let error = supabase.authError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.orange.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if supabase.pendingConfirmation {
                Text("Check your inbox to confirm your email, then sign in.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.green.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }

            primaryButton

            Button {
                isSignUp.toggle()
                supabase.authError = nil
            } label: {
                Text(isSignUp ? "Already have an account? Sign in"
                              : "No account yet? Create one")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(22)
    }

    private var signedInContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Account")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 4) {
                Text("Signed in as")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                Text(supabase.userEmail ?? "—")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    .lineLimit(1).truncationMode(.middle)
            }
            syncBox
            Spacer(minLength: 0)
            Button { Task { await supabase.signOut() } } label: {
                Text("Sign out")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.white.opacity(0.16)))
            }
            .buttonStyle(.plain)
        }
        .padding(22)
    }

    private var primaryButton: some View {
        Button {
            Task {
                if isSignUp { await supabase.signUp(email: email, password: password) }
                else { await supabase.signIn(email: email, password: password) }
            }
        } label: {
            HStack(spacing: 8) {
                if supabase.isWorking { ProgressView().controlSize(.small).tint(.white) }
                Text(isSignUp ? "Create account" : "Sign in")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(Capsule().fill(Color.accentColor))
        }
        .buttonStyle(.plain)
        .disabled(supabase.isWorking || email.isEmpty || password.isEmpty)
        .opacity(supabase.isWorking || email.isEmpty || password.isEmpty ? 0.6 : 1)
    }

    private func field(icon: String, placeholder: String, text: Binding<String>, secure: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 16)
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.08)))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var syncBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sync online")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Text("Store your shelf in the cloud so it's available on your other devices. Off = kept on this Mac only.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Toggle("", isOn: $sync.syncEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.accentColor)
            }
            if sync.syncEnabled, !sync.status.isEmpty {
                Text(sync.status)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help("Close")
    }

    /// Same look as the shelf: frosted desktop blur + a dark radial gradient.
    private var shelfStyleBackground: some View {
        GeometryReader { geo in
            ZStack {
                VisualEffectBlur()
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: .black, location: 0.0),
                        .init(color: .black.opacity(0.25), location: 1.0),
                    ]),
                    center: UnitPoint(x: 0.5, y: 0.16),
                    startRadius: 0,
                    endRadius: hypot(geo.size.width, geo.size.height)
                )
            }
        }
    }
}
