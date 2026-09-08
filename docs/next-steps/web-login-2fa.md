# Web login / 2FA — next patch

## Scope

Keep DSM's own web login and push approval unchanged. Improve the native
sheet, session bridge, OTP retry, and recovery with small changes. No
private Secure SignIn challenge replay or new dependencies. Web login stays
off by default, with an explicitly experimental opt-in for testing.

## Investigation

The current bridge copies an `id` cookie to `_sid` and drops the CSRF token.
It also treats a navigation plus an arbitrary first `id` cookie as completion.
A web login can finish without navigation, or set cookies before the desktop
is ready. Cookie selection does not check expiry, path, or transport.

The [official DSM Login Web API guide](https://global.download.synology.com/download/Document/Software/DeveloperGuide/Os/DSM/All/enu/DSM_Login_Web_API_Guide_enu.pdf)
requires `SynoToken` on requests when CSRF protection is enabled. Code 105
means permission denied; it does **not** establish that the session name is
the cause. Missing CSRF context is a concrete client defect and a plausible
contributor to the reported 105, not a confirmed diagnosis on the user's NAS.
Package/account permissions or DSM-specific web/API restrictions remain
possible. The earlier credential-free `method=login` attempt returned 400
(commit `0c0a2a2`); do not repeat it as a supposed session upgrade.

## Implemented in Unreleased

- Query the documented `SYNO.API.Auth.token` endpoint in the web page's
  cookie context (guide pp. 17–18), with same-origin checks before and
  after asynchronous work and redirects disabled. No private login replay.
- Preserve SID + optional token as one `AuthSession` through native login,
  API forms, DS2 multipart upload, Keychain restore and cleanup.
- Fix a second, independently reproduced persistence defect: generic
  Keychain passwords are unique by service/account, not label. SID,
  cookies and metadata previously collided (`errSecDuplicateItem`, -25299).
  Services now include credential kind, with legacy reads and cleanup.
- Use an origin-specific web session slot without assuming the native
  username. Clear the prior native password on completed web handoff.
- Require an explicit completion check instead of guessing from navigation.
  Keep failed-check feedback in the sheet, with reload, cancel and the
  existing certificate pinning policy. No automatic trust of unknown certs.
- Require a real Download Station probe. Rejected candidates are cleared;
  failed checks keep the candidate only in memory for retry. OTP fallback
  and a fresh web login remain available.
- Keep OTP fields visible while verifying and after an incorrect code;
  expose experimental web sign-in in login Settings, default off. New
  text is translated into Czech.

## Validation

- iPhone 17 Pro / iOS 26.5: 85 unit tests pass in English and Czech.
- Coverage includes cookie origin/path/expiry/transport and ambiguity,
  token parsing, legacy Keychain migration and coexisting records, request
  encoding including multipart, 105 cleanup, offline retry, cold restore
  without a native username, and wrong-code/transport OTP retry.
- Four pre-existing assertions assumed English output. They now compare
  localized expected labels/messages so the normal Czech simulator run
  can pass without changing device language.
- Full visual walkthrough (Czech, Dynamic Type, dark/light, web sheet and
  OTP/recovery states) remains manual follow-up. Simulator UI automation did
  not respond to in-device input during this run.
- This validates client behavior with synthetic sessions, **not** a real
  DSM push approval, web-page compatibility, or package permissions.

## Acceptance checklist

- Carry SID and optional CSRF token together through API requests, Keychain
  restore, and cleanup, including multipart uploads. Never log their values.
- Restrict bridge extraction to the configured NAS origin and applicable
  cookies; do not trust redirect destinations or identity from the native
  username field. Keep the final Download Station probe mandatory.
- Provide an explicit completion/check action for DSM pages that use XHR
  without navigation. Explain TLS/load errors and allow reload/cancel.
- Preserve a candidate on transient validation failure for retry; clear a
  rejected candidate and offer verification-code fallback.
- Keep OTP entry visible during verification and after an incorrect code.
- Run parser/request/session tests and the full iPhone 17 Pro simulator suite.

## Real-NAS release gate (still required)

Test DSM version/build, Download Station version, push approval and web OTP,
CSRF on/off, app permissions denied, fresh login, cold restore, expired
session, offline probe/retry, cancellation, and self-signed certificate.
Record outcomes without SID, tokens, cookies, passwords, or OTPs. Do not
promote the option to supported beta based on mocked tests alone.
