# Roadmap — quick reference

This file is a discoverable entry point. The full roadmap, with
philosophy, priorities, and the per-bucket breakdown, lives in
[`docs/roadmap/ROADMAP_V2.md`](docs/roadmap/ROADMAP_V2.md) — that is
the single source of truth for product direction.

## Product direction

DropStation is evolving into a **premium native NAS companion** for
Synology Download Station — not a torrent-client kitchen sink.

Priority: clarity, reliability, speed, native feel, calm utility UX.

## Current focus (TestFlight beta / 0.5.3)

DropStation is in the internal TestFlight beta phase. The repo
is on `0.5.3`, build `15`. The release-engineering loop is
proven (App Store Connect upload, TestFlight distribution,
Xcode Cloud bootstrap) and the app now ships in English **and
Czech**.

Shipped on `main` since 0.5.0:

- ✅ Dashboard hero three-way state (no more "0 KB/s Working…")
- ✅ Downloads list readability polish
- ✅ Light-mode hairline contrast
- ✅ Settings destructive-action toned down
- ✅ Placeholder Quick Actions removed
- ✅ `DownloadTaskStore` — shared task layer
- ✅ Real free-disk space in the dashboard hero
- ✅ Self-signed certificate trust prompt + pinning + retry
- ✅ Active now dashboard section for live transfers
- ✅ Per-file skipped / completed / downloading hierarchy
- ✅ In-app bug report form with safe diagnostics
- ✅ TestFlight readiness fixes (`Info.plist`, build numbering,
  iPad orientations, Xcode Cloud bootstrap)
- ✅ **Czech localization** — String Catalog with 221 keys, full
  Czech translation pass for the 0.5.3 release

Current work includes beta hardening; the requested visual refresh is tracked
in the full roadmap and the Unreleased changelog:

- ⏳ Run the TestFlight smoke checklist on the installed build
- ⏳ Watch TestFlight crashes / hangs after daily use
- ⏳ Keep bumping `CURRENT_PROJECT_VERSION` for every upload
- ⏳ Prepare the next build notes from
  [`docs/release/release-notes-template.md`](docs/release/release-notes-template.md)
- ⏳ Decide when Phase 1 solo internal beta is stable enough for
  3-5 trusted testers
- ⏳ cs-locale UI walkthrough — Czech is 20-30% longer than
  English on average; verify no buttons wrap or truncate
- ⏳ Plural-rule entries for `%lld file` etc. (Czech has three
  forms; needs xcstrings plural-variation UI)
- ⏳ `No %@ downloads` adjective inflection — per-filter empty-
  state strings in TaskListView

See [`docs/next-steps/0.5.2-active-state-bug-report.md`](docs/next-steps/0.5.2-active-state-bug-report.md)
for the prior feature batch,
[`docs/i18n/terminology.md`](docs/i18n/terminology.md) for the
Czech translator glossary, and
[`docs/release/`](docs/release/) for the TestFlight operating
documents.

## Beyond Internal Beta

After the solo TestFlight build is stable: daily usability (Share
Extension, notifications, multi-server, richer task detail), then
App Store readiness proper (localization, accessibility,
screenshots, review submission). Power-user features (RSS,
widgets, automation) stay behind stability + App Store readiness.

Full breakdown: [`docs/roadmap/ROADMAP_V2.md`](docs/roadmap/ROADMAP_V2.md).

## Other docs

- [`docs/ux/design-principles.md`](docs/ux/design-principles.md) —
  visual language rules (DSStatusDot ambient / DSStatusBadge
  exceptional, one primary glass per screen, …).
- [`docs/reviews/`](docs/reviews/) — UI review notes per release.
- [`docs/releases/`](docs/releases/) — release-level summaries.
- [`docs/next-steps/`](docs/next-steps/) — work tracking for the
  next release.
- [`docs/release/`](docs/release/) — release engineering: TestFlight
  readiness audit, action checklist, rollout plan, release-notes
  template, and dev-install-vs-TestFlight reference.
- [`CHANGELOG.md`](CHANGELOG.md) — short user-facing changelog
  (bundled into the app's Settings → Version → What's new).

## Maintenance

When implementation diverges from these docs, the docs change
first — not chat history, not commit messages. See
[`AGENTS.md`](AGENTS.md) for the contributor workflow.
