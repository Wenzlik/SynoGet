# DropStation - Roadmap V2

## Philosophy

DropStation is evolving from:
- a hobby NAS utility
- into a premium native iOS companion app for Synology Download Station.

Priority:
- clarity
- reliability
- speed
- native feel
- calm utility UX

Not:
- feature overload
- analytics dashboards
- automation-heavy complexity

---

# Foundation

## Completed

### Authentication & session
- OTP authentication
- Persistent SID sessions
- Automatic reconnect behavior with `NWPathMonitor` driving the
  Connection lost / auto-reconnect surface
- Session persistence controls (Settings → Privacy → Remember
  session)
- Better offline handling — transient transport-layer failures
  preserve the cached SID, only DSM-confirmed expiry codes
  (105 / 106 / 107 / 119) wipe it

### Visual layer
- Dashboard-first UX (post-login landing screen with focal
  speed / state / metric hierarchy)
- DesignSystem foundation (~20 reusable components: DSCard,
  DSSectionCard, DSHeroCard, DSEyebrow, DSStatusDot, DSStatusBadge,
  DSAvatarCircle, DSQuickAction, DSActivityRow, DSMetricRow,
  DSGroupedRows, DSStatTile, DSProgressSliver, DSRowButtonStyle,
  DSEmptyState, DSErrorState, DSLoadingView + design tokens)
- Downloads redesign (single grouped surface, status dot inline,
  progress sliver, metadata hierarchy)
- Settings redesign (ScrollView + DSSectionCard, account
  identity hero with DSAvatarCircle)
- Modernized login flow (Phase-3 surface treatment, eyebrow
  state headers)
- Polish pass — hero three-way state classifier (no more
  "0 KB/s Working…" frozen-bug look), tiered Downloads metadata,
  light-mode hairline contrast, quieter destructive actions,
  placeholder Quick Actions removed

### Shared infrastructure
- **`DownloadTaskStore`** — single `@MainActor ObservableObject`
  owning the shared `[DownloadTask]` array + 5 s polling timer +
  mutation wrappers (create / pause / stop / resume / delete).
  Dashboard and Downloads tabs read from one source of truth
  instead of running two independent polls.
- Polling lifecycle driven from `RootView.onChange(of: session.state)` —
  starts on `.loggedIn`, stops on every other state. Eliminates
  the cross-tab race the per-view-model timers had.
- 105 forwarding centralised in the store so the recovery card
  receives one signal regardless of which call discovered the
  expired session.
- Free-disk probe wired into the shared task layer and surfaced in
  the dashboard hero when available.
- Self-signed certificate trust-on-first-use flow: certificate
  prompt, user confirmation, Keychain-backed fingerprint pinning,
  certificate-change detection, and retry after trust.
- In-app bug report form with optional safe diagnostics. Reports
  compose through the user's mail account and never include
  passwords, SIDs, cookies, OTPs, tokens, or torrent names.

### Distribution foundation
- Internal TestFlight distribution is live. Current repo
  checkpoint: `0.5.3`, build `15`.
- App Store Connect upload path proven with TestFlight processing
  across the 0.5.2 → 0.5.3 line.
- Xcode Cloud bootstrap added via `ci_scripts/ci_post_clone.sh`
  so fresh cloud clones generate `DropStation.xcodeproj` from
  `project.yml`.
- TestFlight blockers fixed: Local Network usage description,
  export-compliance flag, build numbering discipline, iPad
  orientation set, narrowed ATS (`NSAllowsLocalNetworking`) plus
  explicit self-signed HTTPS trust.

### Localization (0.5.3)
- String Catalog (`Localizable.xcstrings`) with `en` source +
  `cs` target — Xcode 15+ format, auto-extracts from
  `LocalizedStringKey` / `String(localized:)` literals at build
  time, single file per language pair.
- 221 unique source keys, all translated to Czech. Translation
  pass follows the rules in
  [`docs/i18n/terminology.md`](../i18n/terminology.md) (brands
  stay English, "session" → "relace", iOS-Czech matches for
  Sign in / Settings / Cancel / Done, etc.).
- `CFBundleLocalizations = [en, cs]` registered in `Info.plist`
  so iOS exposes the language picker under Settings →
  DropStation → Language.

---

# Current visual pass — next unreleased version

- Cohesive iOS 27-inspired visual pass across login, dashboard, downloads,
  detail, Add download, Settings and recovery states; new original app icon.
- Keep iOS 26 deployment and auth/API behavior. Implementation follows
  [the visual brief](../ux/redesign-ios27.md).

# Current beta hardening

## High priority

- Run the TestFlight smoke checklist on the 0.5.3 build and
  record any failure as a docs-first follow-up.
- Watch App Store Connect TestFlight crash / hang reports during
  solo daily use.
- Keep `CURRENT_PROJECT_VERSION` moving for every new TestFlight
  archive.
- Prepare per-build "What to Test" notes before every upload.
- When solo usage is stable, expand from Phase 1 to 3-5 trusted
  internal testers.
- **cs-locale UI walkthrough** — Czech is on average 20-30%
  longer than English; verify no buttons wrap or truncate
  under the Czech build before declaring the localization
  batch shippable.
- Plural-rule entries for `%lld file` etc. (Czech has three
  plural forms; needs the xcstrings plural-variation UI in
  Xcode, not a string-replacement edit).
- `No %@ downloads` adjective inflection — current Czech
  translation reads "Žádná stahování (downloading)" which is
  functional but ugly. Right fix is per-filter empty-state
  strings in TaskListView (code change, not catalog).

---

# Daily usability

## High priority

### Share Extension

Safari:
```text
Share -> DropStation
```

Goal:
- add torrents/links directly from browser

---

### Notifications

Needed:
- download completed
- failed task
- NAS unreachable

---

### Better task detail

Goal:
- richer metadata
- cleaner hierarchy
- modern detail presentation

---

### Multi-server support

Goal:
- support multiple Synology servers
- quick switching
- future-ready architecture

---

# Distribution

## App Store readiness

- Privacy policy (`docs/release/privacy.md` exists; publish URL
  can point at the GitHub copy until a product site exists)
- App review demo NAS
- Localization
- Accessibility review
- Screenshots & previews
- App Store copy
- Support URL

---

# Power-user features

## Lower priority

- RSS automation
- advanced search
- widgets
- analytics/charts
- automation systems

Avoid prioritizing these before:
- stability
- usability
- App Store readiness

---

# Explicit non-goals

Avoid:
- reverse-engineering Secure SignIn
- giant custom navigation systems
- overbuilt architecture rewrites
- flashy UI trends
- feature creep before stable daily usability

---

## Product direction

Desired identity:

```text
premium NAS companion
```

Not:

```text
torrent power-user kitchen sink
```
