# DropStation

A modern iPhone client for **Synology Download Station** — the replacement for
the discontinued **DS get** app.

> Current version: **0.5.5** — see [CHANGELOG.md](CHANGELOG.md) for what's
> shipping and [ROADMAP.md](ROADMAP.md) for what's planned.
> Picking up the repo as a contributor (or AI assistant)? Start with
> [AGENTS.md](AGENTS.md).

## What it does

DropStation connects to your Synology NAS and lets you manage Download
Station from your iPhone. Sign in with your DSM username + password —
when DSM challenges for a second factor, enter the 6-digit verification
code from a TOTP app ([sign-in methods](#sign-in-methods) below) —
then:

- **Dashboard tab** as the post-login landing — large rounded
  monospaced transfer speed, NAS hostname + Online indicator,
  recent activity feed, quick actions. Glance-and-go control
  center rather than a stats wall.
- **Downloads tab** — every active and recent task in one list,
  status dot + title + monospaced `↓ speed · ETA · size`
  metadata, thin status-tinted progress sliver that hides on
  completion. Swipe to pause / resume / stop / delete.
- Tap a task to drill into peers / seeders / leechers, file list,
  tracker URLs, ratio, and ETA.
- Add a new download by pasting a magnet/URL or picking a `.torrent`
  from the Files app. The destination folder is a tap away — browse
  your NAS shared folders directly.
- Filter the list by Downloading / Seeding / Paused / Finished / Error.
  Sort by name / size / date added / date completed.
- Open magnet links from Safari straight into the app.

The 0.5 visual language is a single design system across every
screen — one primary Liquid Glass surface per screen (the
dashboard hero, the Settings account card, the login card),
material-and-hairline secondary cards everywhere else, status
conveyed by small filled dots rather than tinted backgrounds.
Premium native utility feel; no decorative chrome.

The app stays signed in across launches. The SID, optional CSRF token,
web cookies, and session metadata live in the iOS Keychain. **Remember
session** in Settings → Privacy defaults on; turning it off clears the
persisted session while keeping the current app session active. **Remember
password** is a separate preference (also on by default): native login can
reuse the saved password after session expiry and ask only for an OTP.
Web login does not capture or save the password entered in DSM.

## Sign-in methods

- **Verification code (TOTP)** — The default supported path. Enter your
  username and password; if DSM requires 2FA, enter the rotating 6-digit
  code from your authenticator (including Secure SignIn's Codes tab).
  Incorrect codes can be retried on the same screen.
- **Web sign-in (experimental, off by default)** — From the login screen,
  open Settings and enable **Experimental web sign-in**, then choose
  **Web sign-in**. Complete DSM's own login and push approval / web 2FA,
  then tap **Check Download Station access**. Reload and certificate
  feedback are available in the sheet. Cancel returns to native login.

The experimental bridge queries the documented `SYNO.API.Auth.token`
method inside WKWebView, keeps the CSRF token with the cookie SID, and
requires a successful Download Station API probe before signing in.
A network failure preserves the candidate in memory for **Retry access
check**; a rejected session is cleared and offers verification-code
fallback or a fresh web login. Only validated sessions are persisted.
The existing `auth.method.experimental` defaults flag still works, but
no command-line setup is needed to test the flow.

**Real-NAS compatibility is not yet established.** Error 105 means
permission denied; it does not prove a DSM-web vs. DownloadStation
session-name mismatch. Dropping CSRF context was a client defect, but
account/package permissions and DSM-specific restrictions can still
prevent access. Do not disable NAS security to make the experiment work.
See the [investigation and NAS test matrix](docs/next-steps/web-login-2fa.md).

Web sessions use a separate, origin-specific Keychain slot without claiming
the username typed into the native form. Settings shows a neutral identity;
web-session expiry never silently signs in with another user's saved
password. The next fresh native login asks for the username again.

After a successful sign-in, relaunch reuses the saved session. Network
failures preserve it and show the connection recovery screen; confirmed
session rejection (105/106/107/119) clears it. **Sign out** and **Forget
this device** both clear the current saved session, cookies, metadata,
and saved password, including legacy Keychain records.

## Installing

DropStation is currently distributed as source — there is no public
TestFlight or App Store listing yet. To run it on your own device:

```bash
git clone https://github.com/Wenzlik/DropStation.git
cd DropStation
brew install xcodegen
xcodegen generate
open DropStation.xcodeproj
```

Then build & run on an iPhone simulator or a physical device from
Xcode. On the first launch the app asks for the NAS scheme / host /
port and credentials.

### GitHub Releases

Tagging `vX.Y.Z` produces a [GitHub Release](https://github.com/Wenzlik/DropStation/releases)
via CI with a zipped `.app` attached. **That zip is a simulator smoke-test artefact, not
an installable iPhone build:** it is unsigned, has no provisioning
profile, and cannot be sideloaded onto a physical device or imported
into TestFlight. Use it to verify the tagged commit compiles or to
drop into the iOS Simulator. Proper distribution lands in a later
release once a TestFlight pipeline is set up (tracked in
[ROADMAP.md](ROADMAP.md)).

## Known limitations

- **No installable iOS build.** As above — TestFlight / App Store
  distribution is on the roadmap, not in 0.5.
- **No background refresh / completion notifications yet.** Refresh
  ticks only while the app is in the foreground.
- **Single NAS only.** Multi-server switching is on the 0.5 roadmap.
- **iOS 26 required.** The app leans heavily on iOS 26 Liquid Glass.
- **Web sign-in remains experimental.** Enable it explicitly in login
  Settings for testing. Push/web 2FA and API handoff still require the
  real-NAS compatibility checks linked above.

## Stack

- SwiftUI, iOS 26+ (Liquid Glass design language)
- Swift 5.9, async/await, Codable
- No third-party dependencies
- `actor`-based API client
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) for project generation

## Repository layout

```
DropStation/                The SwiftUI app
├── Models/                 Codable types
├── Networking/             SynologyAPIClient (async/await actor)
├── Storage/                Keychain + UserDefaults persistence
├── ViewModels/             SessionStore + per-screen view models
├── Views/                  SwiftUI screens
└── Resources/              Info.plist + Assets.xcassets (AppIcon)
DropStationTests/           Unit tests
project.yml                 XcodeGen project specification
icon.svg                    Source for the app icon
icon-tinted.svg             Tinted-mode variant (iOS 18+ Home Screen)
```

## Synology API

See the official [Download Station Web API guide](https://global.download.synology.com/download/Document/Software/DeveloperGuide/Package/DownloadStation/All/enu/Synology_Download_Station_Web_API.pdf)
and [DSM Login Web API guide](https://global.download.synology.com/download/Document/Software/DeveloperGuide/Os/DSM/All/enu/DSM_Login_Web_API_Guide_enu.pdf)
for the wire format. Endpoints used:

- `SYNO.API.Auth` — sign-in / sign-out (`auth.cgi`)
- `SYNO.DownloadStation.Task` — list, getinfo, delete, pause, resume,
  and the URI-mode create (`task.cgi`)
- `SYNO.DownloadStation2.Task` — file-upload create at `entry.cgi`
  (DSM 7's newer endpoint; the legacy one silently rejects `.torrent`
  multipart uploads)
- `SYNO.FileStation.List` — list_share / list for the destination picker

Form-urlencoded POST bodies are strictly encoded per RFC 3986 so that
magnet URIs with `&`-separated trackers survive the trip. File uploads
use multipart with the binary as the final part, per Synology's spec.

## License

MIT — see [LICENSE](LICENSE).
