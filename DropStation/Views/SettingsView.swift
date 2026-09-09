import SwiftUI

/// Native grouped settings with a single primary account identity surface.
/// Session controls keep their existing bindings and persistence behavior.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionStore
    @AppStorage(AppearanceSettings.storageKey) private var appearanceRaw: String = AppearanceMode.system.rawValue
    @AppStorage(RememberSessionSettings.storageKey) private var rememberSession: Bool = true
    @AppStorage(PasswordPersistenceSettings.storageKey) private var rememberPassword: Bool = true
    @State private var confirmForget = false

    private var appearance: Binding<AppearanceMode> {
        Binding(
            get: { AppearanceMode(rawValue: appearanceRaw) ?? .system },
            set: { appearanceRaw = $0.rawValue }
        )
    }

    /// Settings can be reached from both the task list (logged in) and the login
    /// screen (logged out). Hide account controls in the latter case — they would
    /// just sign-out an already-signed-out session.
    private var isSignedIn: Bool {
        session.state == .loggedIn
    }

    var body: some View {
        NavigationStack {
            Form {
                if isSignedIn {
                    Section {
                        DSCard(.primary) { accountIdentityRow }
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                    accountSection
                }
                appearanceSection
                privacySection
                feedbackSection
                aboutSection
            }
            .dsFormCanvas()
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(DSRadius.hero)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Forget this device?", isPresented: $confirmForget) {
                Button("Forget", role: .destructive) {
                    Task {
                        await session.forgetDevice()
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes the saved session from the Keychain. Next sign-in will ask for your password and any 2FA code from scratch.")
            }
        }
    }

    // MARK: - Account

    /// Account actions remain a native group below the identity hero.
    private var accountSection: some View {
        Section {
            Button {
                Task {
                    await session.logout()
                    dismiss()
                }
            } label: {
                settingsLabel("Sign out", "rectangle.portrait.and.arrow.right")
            }
            Button(role: .destructive) {
                confirmForget = true
            } label: {
                settingsLabel("Forget this device", "trash", tint: .red)
            }
        } footer: {
            Text("Sign out clears the saved session. Forget this device additionally removes any legacy credentials older builds may have stored.")
        }
    }

    /// Avatar + account label + ambient status line, as a single
    /// grouped row.
    private var accountIdentityRow: some View {
        HStack(spacing: DSSpacing.md) {
            DSAvatarCircle(
                account: session.config.account.isEmpty ? "DS" : session.config.account,
                size: 60
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(session.config.account.isEmpty ? "DropStation" : session.config.account)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    DSStatusDot(tint: .green)
                    Text("Online").font(.caption).foregroundStyle(.secondary)
                }
                Text(session.config.host)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text(Self.versionString).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, DSSpacing.xs)
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker(selection: appearance) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            } label: {
                settingsLabel("Theme", "paintpalette")
            }
        }
    }

    // MARK: - Privacy

    /// Controls credential persistence. Default ON: the app caches the
    /// Download Station SID in the Keychain so cold starts can skip the
    /// OTP prompt. Switching OFF clears every saved credential we hold
    /// for the current account (SID, cookies, metadata, password). The
    /// active in-memory session keeps working until the next launch.
    private var privacySection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { rememberSession },
                set: { newValue in
                    rememberSession = newValue
                    session.setRememberSession(newValue)
                }
            )) {
                settingsLabel("Remember session", "lock.rotation")
            }
            Toggle(isOn: Binding(
                get: { rememberPassword },
                set: { newValue in
                    rememberPassword = newValue
                    session.setRememberPassword(newValue)
                }
            )) {
                settingsLabel("Remember password", "key")
            }
        } header: {
            Text("Privacy")
        } footer: {
            Text(privacyHelperText)
        }
    }

    /// Helper copy under the Privacy section. Spells out the OTP-only
    /// recovery flow when "Remember password" is on, since that's the
    /// behaviour most users are looking for.
    private var privacyHelperText: LocalizedStringKey {
        switch (rememberSession, rememberPassword) {
        case (_, true):
            return "Your session and password are stored in the iOS Keychain. When the session expires you'll only be asked for your verification code, not your password."
        case (true, false):
            return "Your session is stored in the iOS Keychain so the app stays signed in across launches. Your password is not saved."
        case (false, false):
            return "Nothing is saved. You'll sign in with your password and verification code every time you open the app."
        }
    }

    // MARK: - Feedback

    private var feedbackSection: some View {
        // Suggest a feature stays on GitHub: feature requests are
        // discussions that benefit from being public — anyone can
        // upvote, comment, propose alternatives — and a GitHub
        // account is the right friction filter for that surface.
        //
        // Report a bug moves in-app: bug reports want low friction
        // (the user is already frustrated) and benefit from
        // structured fields plus optional diagnostics.
        Section {
            Link(destination: URL(string: "https://github.com/Wenzlik/DropStation/issues/new?template=feature_request.md")!) {
                settingsLabel("Suggest a feature", "lightbulb", trailing: "arrow.up.right")
            }
            NavigationLink {
                BugReportView()
            } label: {
                settingsLabel("Report a bug", "ladybug")
            }
        } header: {
            Text("Feedback")
        } footer: {
            Text("Bug reports send via your mail app. Feature requests open on GitHub.")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            LabeledContent {
                Text("DropStation")
            } label: {
                settingsLabel("App", "app.gift")
            }
            // Tappable Version row: pushes the in-app changelog.
            NavigationLink {
                ChangelogView()
            } label: {
                HStack {
                    settingsLabel("Version", "number")
                    Spacer(minLength: DSSpacing.sm)
                    Text(Self.versionString)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Link(destination: URL(string: "https://github.com/Wenzlik")!) {
                settingsLabel("Made by @Wenzlik", "person.circle", trailing: "arrow.up.right")
            }
            Link(destination: URL(string: "https://github.com/Wenzlik/DropStation")!) {
                settingsLabel("Source on GitHub", "chevron.left.forwardslash.chevron.right", trailing: "arrow.up.right")
            }
        } header: {
            Text("About")
        } footer: {
            Text("© 2026 Vasek Zmrhal · MIT License")
        }
    }

    // MARK: - Helpers

    /// A grouped-list label: accent-tinted leading SF Symbol + primary
    /// title, with an optional quiet trailing glyph (e.g. the external-
    /// link arrow on `Link` rows). Tint overridable for the
    /// destructive Forget row.
    private func settingsLabel(
        _ title: LocalizedStringKey,
        _ symbol: String,
        tint: Color = .accentColor,
        trailing: String? = nil
    ) -> some View {
        HStack {
            Label {
                Text(title).foregroundStyle(tint == .red ? Color.red : .primary)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.10), in: .rect(cornerRadius: 9))
            }
            if let trailing {
                Spacer(minLength: DSSpacing.sm)
                Image(systemName: trailing)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
