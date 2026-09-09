# DropStation — forward visual pass

This brief supersedes the surface proportions in redesign-ios26.md, retaining
native navigation, semantic status colors and one primary glass per screen.
Target: next Unreleased entry after 0.5.5. Requested by Václav.

- Larger continuous corners: 28 pt content cards, 34 pt heroes, 18 pt fields.
- Shared restrained background, readable material surfaces, generous spacing.
- Dashboard: distinct server header and live metric; preserve all three states.
- Downloads: two-line titles, quieter quality tags, legible live metadata.
- Detail: primary glass progress hero, native metric groups and action capsules.
- Login: original brand mark, clean primary card, same credential/OTP flow.
- Settings: native Form with a separate account hero, titled privacy/appearance/
  support/about groups, matching icon tiles. Existing toggles retain semantics.
  Experimental web auth stays hidden; no new flag or auth path is exposed.
- Add: source identity header, native fields, prominent submit; keep full-height
  scrolling for keyboard, large text and destination navigation.
- Empty/error/recovery: shared icon treatment and background, native retry.
- Icon: original folded D / paired storage rails, inspired by a docking station
  and data arriving at a personal archive, not a download arrow or vendor logo.
  Editable SVG sources; opaque 1024 px light/dark/tinted catalog entries.

“iOS 27” describes aesthetic intent, not an Apple API claim. Installed Xcode
26.6 provides iOS 26 SDK APIs; deployment remains iOS 26.0. No speculative APIs,
third-party dependencies, network changes, or release version bump.

Validation: simulator build and existing unit suite, light/dark login and
Settings inspection. Authenticated states require fixture previews or a NAS;
record actual coverage and remaining device checks in the implementation PR.
