# Native message notifications

Android FcmService handles message, share_message and share_part. The iOS source
now uses APNs for those same delivery hints. A hint cannot carry an opening or
grant. Apple receives only event kind, server name and the opaque guest-key hash;
message text, ciphertext, object names, credentials and locations stay out of the
provider payload. Generic OS message alerts have all seven existing localizations.

AppRemoteNotifications registers a device token only with entrixy.com. It never
automatically gives the installation-wide Apple token to a self-hosted server.
Other servers can support the authenticated read-only message_pending endpoint;
without it, errors back off without changing installed access.

The protected, backup-excluded inbox stores at most64 coalesced hints and no
message text or access credentials. A background notification can persist a hint,
but cannot resume sockets or execute a command. After the ordinary unlock,
device-signed HTTP reads the current pending ciphertext. Existing MessageManager
authenticates/decrypts, saves locally and only then acknowledges delivery. Read
acknowledgement remains tied to the person's existing message Close action.
Direct-owner messages are ignored for delegated recipients, following Android.

Token rotation, foreground cancellation, in-flight key removal and concurrent
hints are guarded. A local key deletion saves first and then attempts an
authenticated token unsubscription after any in-flight registration. Offline or
lost-reply unsubscribe is best effort: server token expiry and real-device tests
remain necessary; this is not a proven offline subscription-removal guarantee.

The server source adds api/native_push_register.php, api/message_pending.php,
lib/native_push.php, a separate CLI worker and optional2026-11_native_push.sql.
FCM's existing request only queues an allowlisted APNs hint. Synchronous Apple
HTTP is never added to the web request or the websocket event loop. The worker
uses HTTPS/HTTP2, ES256 provider tokens, production/sandbox separation, bounded
backoff, exact outbox revision checks and invalid-token retirement. Missing
provider configuration leaves the APNs branch disabled and preserves Android FCM.

Before real delivery: confirm signing identifiers; enable the app's push
capability; configure the provider key outside the document root; apply the
optional schema and install the separately locked CLI worker. Those actions
have not been performed. No Apple credential is present in source or CI and no
real notification was sent during implementation. Signed device registration,
APNs delivery, background/locked/force-quit behavior and migration require actual
device acceptance. No claim of guaranteed background delivery is made.

Four core API/payload cases and six hosted flow cases passed in
[CI44521810979](https://github.com/entrixy/ios-build./actions/runs/44521810979),
exact nativeec2c81f/public487b2f6:312core/191hosted/27UI and all56original
checkpoints. This is isolated SDK/runtime verification, not a real APNs send.
Current baseline and remaining delivery gates: [CURRENT_STATUS.md](CURRENT_STATUS.md).

Primary references:

- [Register with APNs](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns)
- [Send APNs requests](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)
- [Token-based APNs connection](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)
- [Background updates](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)

Local checks19November:312core passed; whole app/widget/hosted/UI syntax passed.
Server23pure provider contracts and22disposable MariaDB/HTTP contracts passed, using
only temporary fixture keys and mock HTTP callbacks. Zero real push sends.
Those checks do not replace signed-device/Apple runtime acceptance.

Backend source is committed as d9ec3b6 in the website repository. The22database/
HTTP checks include actual device signatures, copied-link refusal, replay,
company/disabled-key refusal and exact subscription removal. Object pause does
not prevent encrypted messages, matching the existing Android message authority.
The default private provider configuration is absent; migration/worker install
were not applied to production. Current host PHP supports PDO MySQL and curlHTTP2.
