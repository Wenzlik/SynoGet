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

## Acceptance

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
