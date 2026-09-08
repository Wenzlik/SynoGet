import SwiftUI

/// Settings on a native grouped `Form` — the iOS 26 redesign moved off
/// the hand-rolled `ScrollView` + `DSSectionCard` stack (which
/// approximated the system list and drifted into uncanny-valley
/// "almost native") back to the real thing. The account block stays a
/// distinct identity row at the top of its section — it earns the
/// prominence — while every other section is a plain native grouped
/// section with a footer, so the screen reads unmistakably as iOS.
///
/// Coloured leading SF Symbols are kept (via `settingsLabel`): the
/// grouped-list row is the one place the native Settings idiom wants
/// colour in the icon slot.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionStore
    @AppStorage(AppearanceSettings.storageKey) private var appearanceRaw: String = AppearanceMode.system.rawValue
    @AppStorage(RememberSessionSettings.storageKey) private var rememberSession: Bool = true
    @AppStorage(PasswordPersistenceSettings.storageKey) private var rememberPassword: Bool = true
    @AppStorage(AuthMethodSettings.experimentalEnabledKey) private var experimentalWebLogin = false
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
                if isSignedIn { accountSection }
                appearanceSection
                privacySection
                if !isSignedIn { experimentalSignInSection }
                feedbackSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
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

    private var experimentalSignInSection: some View {
        Section {
            Toggle("Experimental web sign-in", isOn: $experimentalWebLogin)
        } footer: {
            Text("Adds DSM web sign-in for testing push approval and web 2FA. Some NAS configurations reject Download Station access. Verification code sign-in stays available.")
        }
    }

    // MARK: - Account

    /// Identity row + the two account actions, grouped like the
    /// Apple-ID block at the top of system Settings: the avatar/name/
    /// status row, then Sign out, then a destructive Forget this
    /// device. Footer carries the explanatory copy.
    private var accountSection: some View {
        Section {
            accountIdentityRow
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
            Text("Both actions clear the saved session and password. Your server address and preferences are kept.")
        }
    }

    /// Avatar + account label + ambient status line, as a single
    /// grouped row.
    private var accountIdentityRow: some View {
        HStack(spacing: DSSpacing.md) {
            DSAvatarCircle(
                account: session.config.account.isEmpty ? "DS" : session.config.account,
                size: 52
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(session.config.account.isEmpty ? "DropStation" : session.config.account)
                    .font(.headline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    DSStatusDot(tint: .green)
                    DSMetricRow(values: accountMetrics, font: .caption)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, DSSpacing.xs)
    }

    /// "Online · nas.local · 0.5.4 (16)" — host dropped if the config
    /// is empty (defensive). Version always surfaced for at-a-glance
    /// debug context.
    private var accountMetrics: [String] {
        var values: [String] = ["Online"]
        if !session.config.host.isEmpty {
            values.append(session.config.host)
        }
        values.append(Self.versionString)
        return values
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section {
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
                Image(systemName: symbol).foregroundStyle(tint)
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
