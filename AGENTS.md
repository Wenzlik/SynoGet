# AGENTS.md

A briefing for AI coding assistants (Claude Code, Cursor, Aider, Copilot, …)
and human contributors picking up this repo for the first time.

## The fast read

In order:

1. **[README.md](README.md)** — what the app does and how to build it.
2. **[ROADMAP.md](ROADMAP.md)** — what's planned, broken down by version
   (0.3.1, 0.4, 0.5, 0.6) with implementation notes already filled in.
3. **[CHANGELOG.md](CHANGELOG.md)** — what shipped in each release.
4. **Recent commit messages** — a lot of the "why" lives in commit bodies,
   not just subject lines. `git log --oneline -20` is a good orientation,
   `git log -p -1` on any surprising line shows the reasoning.

If something in the codebase looks odd, check the commit message that
introduced it before changing it — most of the workarounds here exist for
a documented reason.

## Stack

- **iOS 26+**, SwiftUI, Swift 5.9, async/await + actor
- **No third-party dependencies, ever.** Standard library + Foundation +
  SwiftUI + Network + LocalAuthentication only.
- **XcodeGen** for project generation. `DropStation.xcodeproj` is
  gitignored — regenerate from `project.yml` whenever you change source
  layout or build settings.

```bash
brew install xcodegen
xcodegen generate
open DropStation.xcodeproj
```

## Project shape

```
DropStation/                The SwiftUI app
├── Models/                 Codable types, plain structs
├── Networking/             SynologyAPIClient (actor) + response shapes
├── Storage/                Keychain + UserDefaults
├── ViewModels/             SessionStore + per-screen view models
├── Views/                  SwiftUI screens, one file per screen
└── Resources/              Info.plist + Assets.xcassets
DropStationTests/           Unit tests, run via Xcode (⌘U)
project.yml                 XcodeGen specification
icon.svg + icon-tinted.svg  App icon sources (rendered to PNG with rsvg-convert)
```

## Codebase quirks worth knowing

- **File uploads of `.torrent`** go through
  `SYNO.DownloadStation2.Task` at `/webapi/entry.cgi`, not the
  documented DS1 endpoint at `task.cgi`. DS1 silently rejects
  multipart uploads on DSM 7 with `101 Invalid parameter`. The DS2
  payload needs `type`, `destination`, `create_list`, `mtime`, `size`,
  `file=["torrent"]` and the binary as the final part, with `_sid` in
  the URL query.
- **Form-urlencoded values** use a strict RFC 3986 unreserved character
  set (alphanumerics + `-._~`). The default `.urlQueryAllowed` permits
  `&` `=` `+` inside values, which breaks magnet URIs that carry
  multiple trackers — the server parses the trailing `&tr=…` chain as
  new form parameters.
- **Every numeric Synology field** is wrapped in `FlexibleInt64`
  because DSM is inconsistent about returning numbers as JSON numbers
  vs quoted-string numbers vs floats. Same field can come back as
  `5368709120`, `"5368709120"`, or even `5.36e9` across DSM builds.
- **Native login uses TOTP; experimental web login uses DSM's own 2FA.**
  The public credential login does not drive push approval. The opt-in
  WKWebView sheet queries the documented `SYNO.API.Auth.token` method,
  bridges SID + CSRF context, then validates Download Station access.
  Error 105 means permission denied, not proof of a session-scope mismatch.
  Real-NAS compatibility remains a release gate; see
  `docs/next-steps/web-login-2fa.md`.
- **Keychain labels are not unique keys.** Credential kinds use separate
  service namespaces. Keep legacy reads and cleanup when changing storage;
  SID + token must remain paired in one `AuthSession` record.
- **Launch-time session restore** is driven by `.task` on
  `DropStationApp`'s `WindowGroup`, not from `SessionStore.init()`. The
  `restoreOnLaunch()` entry point is idempotent via a
  `didRestoreOnLaunch` flag.
- **Transient errors** during the background poll (URL errors, HTTP
  5xx) are silently swallowed — see `APIError.isTransient`. The
  list keeps its last good state and the next 5 s tick recovers. Only
  user-initiated actions surface alerts.
- **Status pill / progress tint / type icon** mappings live as
  extensions on `DownloadTask.Status` and `DownloadTask.TaskType`. Add
  new mappings there so views stay in sync.

## Style notes

- **No third-party dependencies.** If a feature really needs one, raise
  it in an issue first; default answer is "find an Apple API".
- Multi-line commit messages with a subject + body that explains
  **why**, not just **what**. The repo's history is a useful
  reference, please don't degrade it.
- Comments where intent matters (especially empty catch blocks for
  transient errors, "magic" Synology fields like `file=["torrent"]`).
- One-word brand name: **DropStation**, no space. Bundle id
  `com.wenzlik.DropStation`.

## Trademark caveat

**Synology** is a registered trademark. Don't:

- Put "Synology" in the app's display name, icon, marketing screenshots
  or App Store name.
- Imitate Synology's brand visuals (colour scheme, iconography).

Do:

- Reference "Synology Download Station" in the App Store description
  with the disclaimer: *"Unofficial client for Synology Download
  Station. Not affiliated with or endorsed by Synology Inc."*
- Mirror that disclaimer in Settings → About once the app reaches
  App Store submission (see ROADMAP 0.6).

## What's not here yet

- **Plural rules** — Czech is shipped (0.5.3, String Catalog with
  221 keys) but the few format strings that need plural-rule
  entries (`%lld file` etc.) still render the singular form.
  Fix needs the xcstrings plural-variation UI in Xcode, not a
  string-replacement edit. See
  [`docs/i18n/terminology.md`](docs/i18n/terminology.md) for the
  translator glossary and conventions.
- **Accessibility audit** — VoiceOver labels and Dynamic Type
  sanity-checking are listed as 1.0 (App Store) gating work.

## Repository protection / PR workflow

As of 0.5.1, `main` is **branch-protected** on GitHub. Direct pushes
are rejected. All work lands via pull request:

```
git checkout -b work/<short-description>
# … commits …
git push -u origin work/<short-description>
gh pr create --base main --fill         # or open via web
# Approve + Squash & merge on the web UI.
git checkout main && git pull --ff-only origin main
git branch -d work/<short-description>
```

Active rulesets (`gh api repos/Wenzlik/DropStation/rulesets` to
inspect):

| Ruleset | Target | Effect |
|---|---|---|
| **main: require PR + protect** | `refs/heads/main` | direct push blocked, force-push blocked, deletion blocked, PR required (0 approvals — self-merge OK) |
| **release branches: no delete / no force-push** | `refs/heads/0.*` | force-push blocked, deletion blocked. Historic release branches are frozen at their tagged commit. |
| **release tags: immutable** | `refs/tags/v*` | tag rewriting blocked, deletion blocked. Once a `vX.Y.Z` tag exists, it's the permanent record of that release. |

There are **no bypass actors** — emergency override is
"Settings → Rules → temporarily disable", do the destructive
operation, re-enable. No accidental force-push or branch deletion
can happen via normal `git push`.

## How to make a change

1. Decide which version it fits — open
   [`docs/roadmap/ROADMAP_V2.md`](docs/roadmap/ROADMAP_V2.md) and find
   the item. If it's not there, add it via the doc-update PR
   workflow before coding. Docs change first, then implementation.
2. Branch from `main`:
   `git checkout -b work/<short-description>`.
3. Implement. If you touched `project.yml`, regenerate the Xcode
   project (`xcodegen generate`).
4. Run tests:
   `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project DropStation.xcodeproj -scheme DropStation -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test`
   Add coverage for any new model or API path. Required: 33/33
   passing.
5. Move the item from `docs/roadmap/ROADMAP_V2.md` /
   `docs/next-steps/<release>.md` into the in-flight version entry in
   `CHANGELOG.md`. Keep the in-app CHANGELOG wording **short and
   user-facing** — technical detail belongs in the commit body and
   GitHub Release notes, not in the bundled changelog.
6. Commit with a multi-line message — subject line under ~70 chars,
   body that explains the why and references API quirks if relevant.
7. Push the feature branch and open a PR against `main`. Self-merge
   on the web UI (Squash & merge preferred). The branch protection
   ruleset enforces the PR step.
8. After merge: pull `main` locally (FF), delete the merged feature
   branch.

## Releases

Cut from `main` once a release-shaped batch of PRs has landed:

1. Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in
   `project.yml` via a release-prep PR.
2. Promote the in-flight CHANGELOG entry to a dated release entry,
   add the GitHub Release link reference at the bottom.
3. Merge the release-prep PR into `main`.
4. Branch the release from `main`: `git branch 0.X.Y main && git push -u origin 0.X.Y`.
5. Tag the release commit: `git tag -a v0.X.Y -m "DropStation 0.X.Y" && git push origin v0.X.Y`.
   The tag push triggers `.github/workflows/release.yml`, which
   builds a simulator-only smoke `.app` zip and attaches it to a
   GitHub Release.
6. The `0.X.Y` branch is then frozen by the
   `release branches: no delete / no force-push` ruleset. Future
   work resumes on `main`.

## Docs as source of truth

Product direction, roadmap, UX rules, and release planning live in
`docs/`. Chat history and commit messages are implementation detail;
the docs are canonical:

- [`docs/roadmap/ROADMAP_V2.md`](docs/roadmap/ROADMAP_V2.md) — full
  roadmap (Foundation / Daily usability / Distribution buckets).
- [`docs/ux/design-principles.md`](docs/ux/design-principles.md) —
  visual language rules (one primary glass per screen,
  `DSStatusDot` ambient / `DSStatusBadge` exceptional, calm motion).
- [`docs/next-steps/`](docs/next-steps/) — work tracking for the
  next release.
- [`docs/reviews/`](docs/reviews/) — UI review notes per release.
- [`docs/releases/`](docs/releases/) — release-level summaries.
- Root [`ROADMAP.md`](ROADMAP.md) — TL;DR pointer at ROADMAP_V2;
  don't maintain two parallel roadmaps.

If implementation conflicts with these docs, **update the doc
first** via its own PR. Don't silently diverge.
