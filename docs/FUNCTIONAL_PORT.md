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
as an ambient scan result. Twenty-three new core tests pass (207 total); three hosted
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

## Camera card follow-on (source)

ActionCard now uses one common owner/guest compound card: the main action remains
independently tappable; a camera icon sits at the right and opens the picture
inside that same card. Always/call/nearby policies open it once and respect manual
collapse. Camera permission/configuration comes only from the selected owner's
private settings or that incoming key's allowed camera bundle. Hidden, paused or
removed incoming objects cannot display a camera.

HTTP images and multipart JPEG use a bounded native loader, original Android
Basic/Bearer/custom-header authentication and timestamp/public-hash placeholders.
Multipart JPEG respects segment lengths, so EXIF thumbnails cannot truncate the
outer frame. Camera secrets cannot follow cross-origin or TLS-downgrade redirects.
Actual frames are decoded/downsampled; invalid bodies, HTTP/TLS errors and first
frame timeouts produce the existing Android stream messages, without endless
placeholders. Leaving the card/background cancels loading/playback. Native public
AVPlayer handles unauthenticated HLS/MP4. RTSP/RTMP/DASH/other codecs and authenticated
video still need their supported media integration; these are not represented as
working video paths. Four core tests pass (207 total), and four hosted sources
exercise scoped HTTP headers, real bytes/decoding, denied responses and multipart.
No new screenshot or live camera/server request was made for this checkpoint.

## Event sounds follow-on (source)

Settings/Sounds now follows the same nine Android event rows and order, with
10% default master volume, actual preview, enabled switch, private file import
and reset. All eleven original Android MP3 resources are copied byte for byte;
no sounds are synthesized or substituted. Invalid imports preserve the old
custom file; unavailable custom audio falls back to its original sample.

The same player handles card taps, confirmation, incoming guest calls, automatic
triggers, biometry, authenticated new messages and actual success/error results.
It mixes respectfully with iOS audio. Local call notifications use a bounded CAF
render of the selected sound/gain, and honor mute/zero volume. Three hosted test
sources cover actual bundled decoding, persistence/import rollback, and mute/
volume-bounded local notification audio. Their Apple execution is pending.

## Guest defaults and cloning follow-on (source)

Presets data is now protected and included in iOS backups: a 40-character owner
name goes only into encrypted host_label, and default object access is applied
when selecting an object for a NEW guest. Changing the default leaves existing
ACLs and guest identities untouched. A name change queues immutable-version
bundle refreshes, preserving in-flight request material and current token expiry.

An explicit clone now has a fresh signing/bundle key and controller DID in its
first request, retaining narrowed access, original force rules/network bans,
per-object choices and welcome. A pending uncertain clone blocks another clone
of the same source until reconciliation, which retains its prepared identity.
Explicit read-only sharing of an existing paused link does not reactivate it.
Three core tests pass (210 total); two hosted sources cover private/default
scope and lost-clone-response recovery. The main Android Guests card/tabs/
company UI is still being ported; this is not a completed Guests screen claim.

## Actual verification

Linux Swift6.0.3 + swift-crypto: 210 core tests, zero failures, including immutable
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

Public0fd8f39d83a33a83783a32c0004729c76fce4234 (native0013921),
[run44078176150](https://github.com/entrixy/ios-build./actions/runs/44078176150),
passed197 Apple core, Debug/Release/isolation and99 hosted tests with zero failures,
including all three new automatic-route failure/replay tests. It predates the
passive-BLE/camera/sound/defaults follow-ons. Public9014ccd/nativea3ad116,
[run44081255143](https://github.com/entrixy/ios-build./actions/runs/44081255143),
subsequently passed203 Apple core, Debug/Release/isolation and101 hosted tests,
including actual fake-radio automatic-write/latch/relaunch checks. No physical
controller was actuated. Camera/sound/default additions have their own pending run.

This does NOT establish native interactions, device operation or App Store readiness. The separate ci/functional-port workflow builds Debug/test
bundles and Release with fixture isolation, without taking screenshots or actuating hardware. It then runs hosted native
transaction tests on an isolated simulator, without UI automation. Its exact-source result is recorded afterward.

## Remaining required implementation and acceptance

- Validate the new foreground any/all runtime and socket revalidation on Apple;
  complete its BLE/background and gated-notification paths.
- Background/permission behavior and physical acceptance of passive BLE on iPhone.
- Verify the new BLE registry move on Apple and real server/controller routes;
  finish remaining guest transfer/product routes.
- Complete authenticated/video codec camera integration and test the new card
  loader on Apple; finish remaining Android guest/company product routes.
- Remaining 62-node gaps documented in IOS_STRUCTURE/ANDROID_IOS_PARITY: company,
  global settings/help/language, restore and device/release integration; native
  execution and backup treatment of new sound preferences/custom files.
- Native functional tests of all changed routes, one final coherent capture batch,
  review and publication, physical device/controller checks, signing and review.

The new editor source is not a claim that the full settings block or application
is finished. Old successful UI tests validate only their original source.

## Guests hub and companies — source checkpoint 17 November

The working Guests root now follows GuestsScreen.kt: People / Companies / Presets,
expandable root-key cards with settings, clone, QR, share, message, pause and delete
in Android order; delegated keys contribute the count below their root instead
of becoming separate owner cards. Received-access cards and their create action
are inline below the owner tabs. Per-object and preset access fields share one
component. Owner name/default rights use the previously protected defaults model.

Company links/QRs are server-scoped, stored before a same-server arrival claim,
and never register an owner or automatically grant access. Company issue/edit is
call-only with depth zero, explicit public object labels and pinned signing keys.
Ordinary sync cannot replace a pin used by an issued key. Explicitly opening a
new company request repins that company's grants as Prefs.setOrgKnownPub does. Company
requests verify Ed25519 over the exact original signed body and bind key_ref,
actor, object and the 600-second window; omitted objects require a singleton
scope. The durable nonce ledger retains 25 minutes as Android does. Actuation
still uses the protected existing call flow and records only a real attempt.
Unknown existing company keys and merged-create replies cannot adopt a new local
signing identity. Directory/pins survive protected storage and iOS backups;
removal waits for confirmed access revocation. Logos are shown only for proven
trusted-server profiles and loaded without redirects/cookies or direct company
site checks.

Linux Swift core: 215 tests, zero failures. App/hosted/UI source parses; localized
labels and diff whitespace pass. Five new hosted scenarios cover arrival scope,
storage failure, ambiguous create, pinned-key rotation/revoke, duplicate merge,
and signed actor/replay. These new native scenarios and changed UI routes have
NOT yet executed on Apple at this checkpoint; the exact-source CI follows this
commit. Functional-port CI also includes the earlier built-test reuse change.
No new screenshots or website publication. UI appearance and physical operation
still require their separate acceptance. Remaining video/background/restore/
global settings and device/signing work above is not marked complete.

## Android backup entry point and resumable signing-key migration — source

BackupManager.inspect now distinguishes authenticated iOS and Android payload
headers after decrypting the common envelope. AndroidOwnerAdapter is connected
to the real import preview. Original preference bytes are retained in protected
state and subsequent encrypted backups, including fields not mapped yet. Owner
name/default rights, server-scoped companies, locally recorded company pins,
private camera settings and hangup preferences are translated. Existing object,
BLE, socket and signing material keeps its original identity. Company recovery
uses the PHONE's saved association and pin, never a company flag from host_sync.

Incoming Android keys migrate using their original per-server Android fingerprint
and signing identity, with their real bundle key or recipient private key when
available. The complete plan is protected before a claim/move; confirmed device
moves are checkpointed before bundle recovery. A missing owner bundle becomes a
persisted waiting key rather than a fabricated decryption key or a migration that
blocks the rest of the app. Recovery is authenticated and can resume after a
restart. Exporting a still-waiting key from iOS rebases its old-device proof to
that exporting iPhone, while retaining the original Android archive separately.
Conflicts and combined archive/directory limits are checked before server moves.
A recovered BLE key is disarmed until a real exit/reentry, including when its
first BLE objects arrive only in the later authenticated bundle.

Prefs.setOrgKnownPub was checked directly: ordinary sync never rotates a company
pin; explicitly opening a new company request updates that company's pins, as
Android does. The model scenario now distinguishes those two paths.

Actual local verification: 219 Linux core tests, zero failures; all App/hosted/UI
Swift source parses and diff whitespace passes. Two new hosted migration cases
cover pre-wire storage failure, restart after a confirmed move, recipient/key
retention, absent bundles, later protected recovery and correct iOS re-export
fingerprints. These additions still require their exact-source Apple run. The
older Guests snapshot is already building/testing separately; do not attribute
its result to these later changes. No UI captures or publication were made.

Remaining Android preferences such as incoming local automation overrides and
passed-link presentation must still be mapped before claiming full backup parity;
retaining their original archive is preservation, not a claim that they are active.

## Header, help and entry-code presentation — source checkpoint

Android MainActivity's Help / language actions are now at the right of the main
header, with all seven original flags copied byte for byte at their source
scales and recorded in asset-provenance.json. Help uses the same six sections and
localized guide links (all seven return HTTPS 200). iOS permissions/call behavior
and current foreground automation are described accurately; Android battery/OEM
instructions and unverified background promises are not copied. Changing language
rebuilds the visible navigation content while preserving the protected AppModel.
This is not a claim that every remaining legacy hardcoded message is translated.

System order starts with Android's theme choices, then the actual entry-code
controls, then backup and servers. Code setup/change and protected lock/biometric
transitions use the common compact dialog over RootView, no task branding or
header cancellation. Existing model persistence, PBKDF/lockout and current-code
checks remain authoritative. A new UI scenario sets a code, verifies wrong-code
rejection when disabling entry lock, then disables it with the correct code.

App/hosted/UI source parses, seven string tables validate without duplicate keys,
21 flag resource hashes match Android and diff whitespace passes. Apple build,
new native UI interactions and final visual acceptance of this checkpoint remain
pending. Functional CI of the previous source is separate. Backup/server controls
and remaining global settings still need the rest of their Android presentation
and service flows. No new screenshots or gallery changes.

## Backup presentation — working source

System now has the Android-positioned Create / Restore actions directly after
entry code. Passwords, file review, progress and result use the shared compact
root dialog; Files and Share are native system presenters. The legacy standalone
backup route reuses these same controls. Opening an .eib or .ekb document prepares
that import UI after app unlock; it never restores automatically. Existing
protected Backend/claim and conflict checks remain in BackupManager.

Password cancellation writes no access state; file cancellation does not mark a
backup saved. Reminders compare captured exported key material with current
material rather than marking every journal/socket update stale. Large provider
files are bounded before decryption. Backgrounding clears password fields and
invalidates a pending presentation; an already-started migration keeps its durable
checkpoints. Encrypted temporary share files are removed after sharing ends.

All source parses, localized string tables validate and whitespace checks pass.
Two new hosted cases cover cancellation and an oversized provider file; their
Apple execution is pending. This checkpoint does not establish live Files/Share,
keyboard layout or UI acceptance. No screenshots were taken.
