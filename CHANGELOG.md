# Changelog

All notable changes to **DropStation** are recorded here. The format is loosely
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Improved
- Experimental web sign-in is available in login Settings, with clearer progress, retry, and verification-code fallback.
- Web sessions now retain the information needed for protected NAS requests and session restore.
- Incorrect verification codes can be retried without leaving the code screen.
- Fixed saved-session storage conflicts and improved Czech sign-in labels.

## [0.5.5] — 2026-07-01 — iOS 26 redesign

### New
- **Open `.torrent` files in DropStation.** Tap a torrent in Files, Safari, or Mail and "Open in DropStation" — it lands in Add download, ready to go (magnet links from Safari already worked).
- **Live Activity & Dynamic Island.** While something is downloading, see the live speed and progress on the Lock Screen and in the Dynamic Island.
- **Long-press a download** for quick actions — Pause / Resume / Stop / Copy link / Delete — and **quick-filter chips** above the list (Downloading / Seeding / Paused / Finished) with live counts.

### Changed
- **A full iOS 26 visual refresh** built around a single clean blue accent and Liquid Glass.
- **Downloads are now media-style cards** with clean titles and quality tags (4K / HDR / Atmos / WEB-DL …) parsed from the raw release name, instead of a dense list of scene filenames. In-flight downloads sort to the top.
- **Clear status at a glance** — colour + icon per state (downloading blue, seeding green, paused orange, done a quiet check) replace the old identical icons.
- **Task detail** now leads with a progress hero and on-screen Pause / Resume / Stop, with metrics grouped into Transfer and Swarm.
- **Add download** has a proper prominent button, **Settings** is rebuilt on a native grouped form, the **login** drops its purple glow, and all-caps section headers become calm sentence case.

<!--
  Release engineering note for 0.5.3 — not rendered in the
  bundled in-app changelog (HTML comments are stripped by the
  markdown renderer).

  The `v0.5.3` git tag points at commit `b6af516` (the PR #13
  merge that landed the Czech translations). That commit still
  has `MARKETING_VERSION = 0.5.2` and `CURRENT_PROJECT_VERSION
  = 14` in `project.yml` — the version bump landed as a
  follow-up PR #14, one commit later, because the bump push
  reached origin/work/localization-foundation after the user
  had already clicked Merge on PR #13. The tag was then cut
  before the rescue PR was identified.

  Per the `refs/tags/v*` ruleset the tag is immutable and was
  deliberately left in place. Real TestFlight builds come from
  Xcode Cloud against post-merge `main`, which carries the
  correct 0.5.3 / 15 identity. The `release.yml` smoke-build
  CI artifact attached to the v0.5.3 GitHub Release reports
  itself as 0.5.2 (build 14) and is simulator-only — keep
  that in mind if anyone goes spelunking the release archive.

  Full incident log lives in `docs/release/process.md` under
  "v0.5.3 tag — premature cut".
-->
## [0.5.4] — 2026-06-14 — Liquid-glass login & saved passwords

### New
- **Remember password.** The app can now keep your password in the iOS Keychain (encrypted, device-bound). When a session expires it re-authenticates on its own and asks for **only** your verification code — never the password again. On by default; toggle it in Settings → Privacy → Remember password. An explicit Sign out / Forget this device always clears it.
- **New app icon with light & dark variants.** A glass water-drop on a glass tray, with dedicated light, dark, and tinted (Home Screen) appearances that follow your system theme.

### Improved
- **Modernized login screen.** A glass droplet brand mark with a blue→purple gradient and soft glow, ambient light blooms behind the sign-in card, and a faint glass rim on the card — matching the new icon's liquid-glass look.

## [0.5.3] — 2026-06-01 — Czech localization

### New
- **Čeština.** DropStation now ships with a full Czech localization alongside English. Switches automatically when iOS is set to Czech, or manually via Settings → DropStation → Language.
- Dashboard now leads with an **Active now** section when transfers are in flight — top 3 byte-moving tasks with live throughput, ETA, and a progress sliver. Idle NAS falls back to the calm Recently completed feed.
- Seeding torrents count as completed content. Idle seeders show up in Recently completed (the file is locally available); seeders currently uploading appear in Active.
- Hero card surfaces upload throughput alongside download as a dedicated `↓ X · ↑ Y` line, not buried in the metric row.
- New in-app **Bug Report** form in Settings → Report a bug. Composes via your mail app (no embedded credentials, no SMTP); attaches optional diagnostics (app/iOS version, device, hostname, auth method, session state) — never passwords, SID, cookies, OTP, or torrent names.

### Improved
- Per-file rows in the torrent detail view distinguish three states visually: **Skipped** (faded, ⊘ Skipped), **Completed** (muted ✓, no progress bar), **Downloading** (thin progress sliver + subtle priority). No more "Low / Normal / High" rendered identically across states.
- Skipped files render reliably even on DSM builds that keep the file's pre-skip priority value after `wanted=false`.

### Notes
- Suggest a feature still opens GitHub — public discussion fits there; bug reports moved in-app where structure and low friction matter more.
- Czech translation pass covers every user-facing string the catalog could extract from source. Plural-rule entries (`%lld file` → 1 / 2-4 / 5+ forms) and adjective-inflection in interpolated filter labels are tracked as follow-ups.

## [0.5.0] — 2026-05-26 — UI modernization

### New
- New dashboard-first home screen.
- Redesigned Downloads screen.
- Redesigned Settings screen.
- Improved connection-lost screen with automatic reconnect.

### Improved
- Cleaner, more modern visual style across the app.
- More readable download status and progress.
- Better session handling when switching networks.
- Verification code sign-in is now the default supported login method.

### Notes
- Secure SignIn remains experimental and hidden by default.

## [0.4.0] — 2026-05-18

### Added
- Sign in via DSM web login in a WKWebView (Synology Secure SignIn push approval works)
- Picker on the sign-in screen to choose verification code vs. Secure SignIn
- Session cookies persisted in Keychain for cross-launch session restore
- **Stay signed in across launches.** Cold start reuses the cached
  Download Station SID — no OTP prompt unless DSM has actually
  expired the session.
- **Foreground revalidation.** When the app comes back from background,
  a silent throttled probe (max once per 10 min) confirms the session is
  still good and surfaces a recovery card if it isn't.
- **"Remember session" toggle** in Settings → Privacy. Default on;
  switching off clears the saved SID, metadata, and cookies and forces
  a fresh sign-in on every cold start.

### Changed
- Sign-out now wipes SID, cookies, session metadata, any legacy
  password, and WKWebsiteDataStore (full cleanup).
- Form sign-in clears DSM trusted-device cookies so 2FA always fires
- Secure SignIn web flow now probes Download Station before declaring
  loggedIn; if DSM rejects API access (error 105), surfaces a recovery
  card with "Continue with verification code" instead of a broken task
  list
- Re-authentication card adapts its heading to the situation — "Session
  expired" when the cached SID timed out, "Re-authentication required"
  when DSM refused API access after a Secure SignIn web login.

### Security
- **Passwords are no longer persisted.** Earlier 0.4 builds saved the
  user's DSM password in the Keychain to enable a silent re-login
  fallback. That cache has been removed; the app only persists the
  Download Station SID + session metadata + Secure SignIn cookies.
  Future builds will reintroduce password persistence as a separate
  explicit opt-in — distinct from "Remember session".
- One-shot migration on launch removes any legacy password an upgraded
  install may still have stored.
- "Re-authenticate now" in Settings is gone — without a saved
  password, "Sign out" achieves the same effect (you sign in fresh).

### Fixed
- Saved SID is no longer thrown away when the launch-time probe fails
  for transient reasons (offline, Wi-Fi handoff, server 5xx); only
  DSM-confirmed session-expiry codes (105/106/107/119) wipe it.

## [0.3.1] — 2026-05-14

### Added
- Stop a finished torrent (swipe or detail menu)
- Confirm delete with Keep-partial-files option
- Paste clipboard URL in new-download form
- Search by name
- Sort by name / size / date added / date completed
- Set BT task priority
- Set per-file priority inside BT torrents
- "Ended" label for paused-at-100 % rows

### Changed
- Tap the Version row in Settings to open the changelog

### Fixed
- No error alert on launch when the saved session expired
- Stop is reversible (Resume reappears)
- Detail-view menu hides when there's nothing to do

## [0.3.0] — 2026-05-13

### Added
- iOS 26 glass cards + status-tinted progress bars
- Type icons next to titles (BT / HTTP / FTP / NZB)
- Tinted-mode app icon for iOS 18+ Home Screens
- Settings reachable from the sign-in screen
- What's new screen in Settings (this changelog)
- Smoothly animated speed / size / progress numbers

### Fixed
- Adding a .torrent file works against DSM 7
- Magnet links with multiple trackers
- Wi-Fi ↔ cellular switch no longer pops error alerts

### Changed
- New downloads default to the File picker
- Dropped leftover third-party attribution (full rewrite)

---

## [0.2] — 2026-05-12

- Task detail screen + destination picker + live speeds
- Split filter (Downloading / Seeding / Active)
- Redesigned login screen
- DSM 7 fixes for `.torrent` uploads and magnet links
- TOTP-only 2FA

## [0.1] — 2026-05-12

Initial release.

[0.5.4]: https://github.com/Wenzlik/DropStation/releases/tag/v0.5.4
[0.5.3]: https://github.com/Wenzlik/DropStation/releases/tag/v0.5.3
[0.5.0]: https://github.com/Wenzlik/DropStation/releases/tag/v0.5.0
[0.4.0]: https://github.com/Wenzlik/DropStation/releases/tag/v0.4.0
[0.3.1]: https://github.com/Wenzlik/DropStation/releases/tag/v0.3.1
[0.3.0]: https://github.com/Wenzlik/DropStation/releases/tag/v0.3.0
[0.2]: https://github.com/Wenzlik/DropStation/releases/tag/v0.2.3
[0.1]: https://github.com/Wenzlik/DropStation/releases/tag/v0.1.0
