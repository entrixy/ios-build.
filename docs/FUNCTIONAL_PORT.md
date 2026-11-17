# Functional Android port — in progress, 16 November 2026

Android reference: full client 10.90, commit 56155352b0e9f36ef3685aa071a6aafdb2ef6622.
Source locations are under app/src/main/java/com/entrixy/app/.
The user requires the same screens, fields, order and actions as Android.
New screenshots follow completion of the functional implementation; none were
made for this checkpoint. The public 19-frame gallery is the previous catalogue.

## Implemented source at this checkpoint

- SettingsScreen.kt AddObjectSheet and EditObjectSheet: call/webhook/device/BLE
  choices before name; phone selection through the system's selected-contact
  picker; webhook URL/secret and phone/server, pulse/toggle controls; device
  registration or case-code claim, private access parameters, persistent app
  binding code; owner-private camera configuration. Editing remains a draft
  until Save. Avatar selection and deletion belong on the object row, rather
  than extra sections inside the editor.
- Device registration is a persisted two-step operation. Registration credentials
  are wrapped before object creation and survive loss of the later response.
  Uncertain sent mutations are reconciled, never automatically submitted anew.
- SnapshotConfig keys and GuestTemplate wire fields match Prefs.kt. Per-object,
  per-issued-key and incoming effective templates are stored independently.
  Incoming owner suggestions/force bounds merge without replacing local choices.
  Camera credentials enter only permitted bundle.cams, never shared object cipher.
- GuestAutomationEditor.kt: any/all, BLE, geo zone/routes, Wi-Fi, time and before
  action authentication/confirmation in Android order. Autosave, individual rule
  levels, geometry inheritance, weekday windows and native map drawing are wired
  to persistent configuration. Publication refreshes existing key bundles through
  a durable version queue, preserving guest identities and an in-flight request.
- SettingsScreen.kt ObjectAvatarBadge: independently tappable avatar, eight owned
  presets and system photo selection, centered square/downsampling/JPEG quality92.
  Owner images use K_obj encryption; incoming overrides are local to one key and
  encrypted with the installation key. Protected state/backup retains overrides.
  Authenticated owner WSS responds to avatar_request with ciphertext only.
- Product wording imports all 890 Android keys for seven languages reproducibly.
  Existing screens still contain untranslated legacy text; this is not full
  localization completion. iOS has no Wi-Fi scan or public call hangup API;
  those limits are explicit, while imported configuration remains intact.

- HostService.postWebhook/fireOwnWebhook/do_webhook: owner phone-mode POST works
  independently of the owner WSS connection; signed guest requests are verified
  against the current authorized key, exact signed direction and persisted replay
  ledger. One in-flight POST per object, journal before send, generic receiver
  failures without leaking local URLs. Response level/message/position/close_in
  follow Android; redirects and application retries are disabled. Request approval
  uses MainActivity.ConfirmDialog's compact global dialog rather than a control
  list card. New hosted tests cover storage-before-POST, no replay and double tap,
  but have not been run on an Apple simulator yet.

- Incoming effective rules are now used by every network/BLE action policy
  decoder and physical FIRE revalidation. Fresh authenticated owner force rules
  override stale local snapshots; local edits invalidate pending authorization.
  The policy pins the exact effective template through PIN/biometry and BLE I/O.
  Server routing, network bans, controller credentials and token validity remain
  authoritative. Unsupported multi-condition gates still block execution.

## Guest-object settings follow-on

GuestsScreen.kt's new/edit key sheet now uses the common ordered object list:
checkbox/name, invocation or BLE lifetime, automation, then object-access icon.
Server groups occur once; choosing objects locks a new key to their owner server.
Video permission stays under the selected camera-enabled row. Removed invented
whole-key confirmation/permission-change toggles and separate permission section.
Nested settings for a new guest use a local form draft and create no signing
identity or server request before Save. Existing per-guest templates and TTL/call
choices persist under that key; camera permission/object scope remain form drafts.
Publication waits while an existing key form is open, so an old bundle in flight
cannot swallow label/scope changes. Failed Save keeps the form when no mutation
was prepared.

Per-object app-only/depth/pool choices use the existing backend fields; app-only
restricts browser access and does not prevent issuing/importing the native key.
BLE TTL has Android's eleven 1-hour…30-day levels, applied only on explicit renewal;
polling and ordinary edits preserve the current token expiry and identity.
Call reactions are owner-private and follow a delegated key back to its root.
Explicit new auto/notify choices hand off to iOS Phone; notification mode waits five
seconds with cancellation, busy checks and one-use signature verification.
Unconfigured older iOS keys retain explicit app approval. iOS always requires its
phone confirmation and cannot dial from the background. App lock blocks management
and automatic handoff. Webhook's invocation setting is the shared object mode,
with Android's warning, not a meaningless per-guest call reaction.

## Verified delegated bundle fulfillment

Owner synchronization now automatically sends prepared recipient bundles after
vouch, parent scope and full-chain verification, matching HostService/Vault.
Parents must be confirmed before descendants become eligible. The exact recipient
key and ciphertext are persisted before upload; ambiguous replies remain sent and
are reconciled on the next sync. No new recipient identity, repeat physical action
or manual owner-approval gate is introduced. The hosted lost-reply test now checks
this automatic path; core chain/forgery tests remain in the regression suite.

## BLE registry move follow-on (source)

ObjectMove.kt now has a durable iOS transaction and the same server selector in
the BLE object editor. The destination receives the same encrypted object, then
the old registry entry is removed. The local UUID, controller DID/secret, pairing,
avatar, automation and catalog position survive; no pairing or actuator packet is
sent. Previous-server guest bundles lose only this object, keeping the same guest
identity and all other token bytes/expiry. Offline revocation delivery remains a
separate operation, as with Android.

Each network phase is saved before sending. An uncertain creation is reconciled
by its exact ciphertext, without a second create. Source rejection rolls back the
destination without revoking existing guests. Local commit is atomic across both
accounts and catalog preferences. Five hosted test sources cover completion,
lost create/delete replies, rollback and failed local storage; these await Apple
execution. Four corresponding core tests pass on Linux. No new capture was made.

## Foreground rule runtime follow-on (source)

GeoCorridorMatcher is ported from the actual Android 10.90 algorithm: 180-second
bounded trajectory buffer, polyline projections, 25m span, speed/near-window
checks, separate urban poor-accuracy evidence and three-fix 90m exit latch.
Zone rules use the Android five-fix inverse-variance smoother, observed outside
entry, ten-second dwell and 180-second rearm/cooldown. Timers without GPS cannot
invent an exit; stale coordinates cannot authorize a physical command. Any/all
and schedule calculations are shared with current-network observations.

The coordinator is connected to production foreground Control. It consumes a
route seen while editing/on another tab, keeps automatic commands open-only and
uses the ordinary identity/policy/journal transactions. Code/confirmation gates
remain manual. Policy and actual condition evidence are rechecked at the first
send and delayed socket challenge. A consumed candidate/lost reply is not replayed.
BLE proximity was subsequently connected as described below. Background
execution is not implemented by this foreground worker.
Ambient Wi-Fi scan rules remain unmet on iOS; the current network is not invented
as an ambient scan result. Nineteen new core tests pass (203 total); three hosted
sources check automatic POST direction, one attempt, changed/expired proof and
storage failure. Apple/runtime validation of this addition is still pending.

## Authenticated passive BLE follow-on (source)

A separate service-filtered CoreBluetooth observer never connects or writes.
Owner radio packets must pass the owner-secret MAC and, where present, the state
MAC. Guest automatic proximity requires the scoped, unexpired grant's state MAC;
a public DID/name alone cannot trigger it. Sleep-aware radio expiry, Android's
5-second RSSI debounce/thresholds and an actual observed absence govern rearming.
Unsigned old/guest sleep metadata cannot shorten that absence window.

Automatic BLE stays armed through proximity until consumed once. Its disarmed
latch is protected before GATT and again atomically with the final proof/journal;
relaunch and restoration cannot repeat the old approach. Registry move carries
the latch to the new server slot. Own GATT/background gaps do not count as a radio
exit. Open/opening bistable state skips an automatic toggle; current authenticated
state and all conditions are rechecked before FIRE. Manual/code-gated paths and
expired/revoked grants retain their guards. Old guest firmware without a state
MAC retains manual access, without invented authenticated passive proximity.

Five new radio/core tests and one BLE-latch/runtime test pass locally (203 total).
Two hosted sources check one automatic write and persistent relaunch latch,
forged discovery rejection and pre-GATT storage failure; the original manual
proof transaction now also asserts durable latch storage. These additions still
require their exact-source Apple run and physical controller tests. No capture
or real controller actuation was performed.

## Actual verification

Linux Swift6.0.3 + swift-crypto: 203 core tests, zero failures, including immutable
in-flight bundle requests, scoped templates, force bounds, overnight windows,
private camera material, stale edit rejection, durable device registration,
avatar rollback, per-key local override isolation and the Android phone-webhook
HMAC format/response/state-expiry rules. New hosted tests also cover one-time
device registration/result storage and retaining newer local rule edits while
recovering an acknowledgement. These are source additions until the exact Apple
run finishes. App and hosted-test Swift
sources passed frontend syntax parsing. Imported strings, YAML/plists and
whitespace checks passed.

Public source 4afbbcbb56a35f386839114ff4331e548a965a2f (native15392b0),
[Apple run43956299201](https://github.com/entrixy/ios-build./actions/runs/43956299201)
passed173 core tests, Debug build-for-testing, Release and fixture isolation.
This confirms the first version of the object/rule/avatar/phone-webhook source
compiles with Xcode26.3. It did not execute hosted tests or UI interactions.
Later effective-policy/recovery/editor changes require their own exact-source run.
No screenshot or physical command was performed.

Public1abcf00cc741abbc302a01633870a926ac27a571 (native854796f),
[run43959028455](https://github.com/entrixy/ios-build./actions/runs/43959028455),
then passed176 Apple core tests, Debug/Release/isolation and88 hosted native tests
with zero failures. Its app/test files are byte-identical to that native checkpoint.
This predates the guest-object settings follow-on above: [run44073814465](https://github.com/entrixy/ios-build./actions/runs/44073814465)
(public3f8ccb4/native2aa672b) then passed180 Apple core, Debug/Release/isolation
and91 hosted tests with zero failures. This predates migration, delegated auto-fulfillment
and the new runtime source. Their own Apple results remain separate.

This does NOT establish native interactions, device operation or App Store readiness. The separate ci/functional-port workflow builds Debug/test
bundles and Release with fixture isolation, without taking screenshots or actuating hardware. It then runs hosted native
transaction tests on an isolated simulator, without UI automation. Its exact-source result is recorded afterward.

## Remaining required implementation and acceptance

- Validate the new foreground any/all runtime and socket revalidation on Apple;
  complete its BLE/background and gated-notification paths.
- Background/permission behavior and physical acceptance of passive BLE on iPhone.
- Verify the new BLE registry move on Apple and real server/controller routes;
  finish remaining guest transfer/product routes.
- Live camera presentation,
  complete per-guest permissions/TTL and corresponding Android product routes.
- Remaining 62-node gaps documented in IOS_STRUCTURE/ANDROID_IOS_PARITY: company,
  global settings/help/language/sounds, restore and device/release integration.
- Native functional tests of all changed routes, one final coherent capture batch,
  review and publication, physical device/controller checks, signing and review.

The new editor source is not a claim that the full settings block or application
is finished. Old successful UI tests validate only their original source.
