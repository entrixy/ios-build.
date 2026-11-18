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


## Server settings and owner account safety — current source, 17 November

Android SettingsScreen.kt's server list is now inline in System, default host first,
custom hosts sorted, current-host radio, scoped account email, aligned edit/trash
icons and a neutral Add Server button. Editing uses the shared root AppDialogSurface,
immutable existing host, access code, optional account credentials or linked-email
unlink, and common filled Cancel/Save controls. No second server menu or object-
creation chooser: new objects use the selected System server. iOS scopes existing
connections by host and does not need Android's process-restart dialog.

The Android API endpoints/fields are preserved: optional meta v1 compatibility,
pwa_login, register_host account_token/access_code and host_account; password and
account token exist only for the one operation, never protected state or backups.
The server account/email and access code survive iOS backup and Android import.
Registration preparation and SENT are durable before wire; a definitive access-code
rejection allows an explicit same-master retry, while ambiguous/legacy sent state
cannot register another owner. Account changes keep a durable pending intent until
an authenticated account field confirms its exact target; absence is not unlink.

Forget removes only the selected local owner/issued material, scoped unsaved state,
order, outgoing messages and sessions; it sends no revoke/delete/register request.
Received keys on the same host, other owners and actual journal history survive.
It is blocked during Bluetooth operations or an unfinished cross-server move.
Restoring old owner credentials requires a backup; simply registering again cannot
promise recovery of anonymous server ownership. Original Android import archives
remain protected for unmapped preferences, as for the rest of Android restoration.

Known eviction/wrong-device/bad-fingerprint stops only that owner's live session,
commands, guest phone requests and owner BLE FIRE/revocation/pairing. Denial stays
in memory if persisting it fails; ordinary sync cannot reactivate it. Only a
successful explicit backup claim can clear the flag. This does not change controller
wire secrets or pretend that an offline phone can learn an unknown eviction.

Local core225 tests zero and Swift frontend syntax passed. Nine new hosted cases
(7 server state/API scenarios and 2 BLE loss-at-scan/nonce cases), and one new UI
server-dialog inspection test are SOURCE ONLY until the next Apple run. Local
syntax is not Xcode typechecking or UI acceptance. The prior native120 success
belongs to nativeeec6bb2/public8fa9d3e, excluding this new block. All new screens
still need actual iOS visual review. No screenshots or website publication yet.

The supplied live PHP checkout has host_account.php but no pwa_login.php; account
sign-in was tested with recorded HTTP fixtures only. Deployment of that Android
endpoint and live account integration must be verified before claiming account
sign-in works on that server. No real password/account/physical controller was used.


## Event sound backup — next source checkpoint

Encrypted iOS exports now include the actual user-selected audio bytes, master
volume and nine event mute choices. Material has a strict event allowlist, no
file paths, per-file and aggregate bounds, and iOS audio decoding before preview
or any server claim. Restoring prepares a complete protected file generation
before claims and validates it again before activation. A failed final access-
state save rolls back the previous sound preferences/files and preserves owner
claim checkpoints; resume never repeats completed owner moves. Legacy iOS copies
without sound material keep current sound settings. Android app_volume/mute_event
preferences are translated; content:// URIs without bytes are explicitly counted
in preview as unavailable and use default samples until the user selects files.
Original Android archives still retain unmapped URI source preferences.

Actual local core228 tests zero; Swift frontend parse and seven Product tables
(912 keys) pass. Five hosted sound/export/restore cases were added as SOURCE only;
expected latest hosted134 pending actual Apple execution. Existing Android MP3s
are unchanged; no audio was generated or replaced. This block has not been
captured/published and does not complete App Store acceptance.


## Android incoming automation restoration — next source checkpoint

Original e2ee_in_tpl_<localKey>_<number> and previous-owner e2ee_in_tplo_* are
translated separately and remain scoped to the exact migrated signing identity,
including keys still awaiting the owner bundle. Immediate recovery, durable waiting
recovery, and a later iOS backup retain these migration seeds. They expose no
objects or action permission. A fresh authenticated bundle first supplies the
actual object and current owner template; Android's existing three-way merger then
preserves user edits and applies current force bounds. Missing previous-owner
history stays unknown and follows Android's first-merge path. Consumed seeds are
removed, and later edits use normal incoming configuration. Another guest/host's
same numeric object cannot contribute a preference.

Actual Linux core231 zero after correcting a missing source-seed TEST fixture;
production archive validation was not weakened. Swift syntax passes. One new hosted
integration source case checks imported PIN through the real protected snapshot/
policy path without sending an action; two migration cases now assert pending and
recovered preferences. Expected latest hosted135 pending Apple execution, not a
pass claim. No new UI or screenshot was introduced by this restore-only change.


## Received-access passing form — current source

Reviewed Android PassOnSection.kt completely before replacing the legacy form.
Create/edit now share one form: name/default Guest, initial encrypted welcome,
allowed objects grouped by host, checkbox left and access icon right. The first
selected object locks the host; no invented server picker, per-key headings,
inline rights steppers or permanent refresh button. Duplicate objects use the
first eligible source as Android does. BLE is included through the already-tested
owner descendant-token path; no copied parent physical identity. Per-object
rights reuse GuestAccessFields with inherited app-only hidden and depth/pool bounded
by the fresh parent allowance. Existing parts and additional same-server source
parts are saved before requests; ambiguous creates retain the same group secret
and reconcile before a repeat. Existing per-object rights can be edited explicitly,
and a local name change preserves the welcome/link/recipient identities. Sender
name is inside the encrypted initial welcome, as in Android. Passed cards now have
settings/copy/QR/share/message/delete in source order; QR uses the shared native
component also used by issued owner keys.

Authoritative clarification from PassOnSection.kt and api/key_delegate.php /
lib/key_objects.php: app-only prohibits browser control, not passing from a native
client. Native passing inherits the parent's exact flag; guest UI cannot change it.
Previously the iOS passing/owner-chain code rejected every app-only descendant.
It now permits valid native chains and still refuses a child row that downgrades
(or otherwise changes) the locally issued flag. Fresh depth/pool and signed-vouch
checks remain. New core cases cover inheritance, inability to downgrade, adding a
source part without replacing secret/welcome, and sender privacy. Hosted cases
cover save-before-wire/lost additional-part replies and explicit ACL edits bounded
by fresh rights. One UI source case covers the same checkbox/access layout without
creating a key. These additions have not yet run on Apple.

Actual Linux235 core tests zero, Swift parse/diff checks pass. Latest expected
hosted137 and UI14 are SOURCE counts, not runtime evidence. Publicb003/native3b165a4
Apple core231 passed, Debug failed at BackupPresentation.swift:185 because the
missing-audio warning was placed outside the preview scope. Moved it into the
actual decrypted review view; no guards or assertions removed. Follow-up Apple
verification must confirm the fix and the new passing code. A separate ci/ui-review
branch now runs the existing native UI suite, without captures or a second hosted
unit run. Standard functional branches retain Debug, Release/isolation and native
checks. No new product PNGs or website changes until the functional batch is ready.


## Follow-up: preserve paired local BLE before HTTP registration completes

Public793e02f/nativee3e25b8 run44113733057/job134145970244 completed the Apple225
core, Debug and Release/isolation checks. Hosted129 executed with TWO assertions
in ONE existing case failing: paired owner BLE before server acknowledgement.
The seven new server cases and two loss-at-scan/nonce cases passed. New denial
logic had incorrectly required HTTP credentials even for an existing authenticated
local BLE pairing. The follow-up treats missing registration as distinct from
known eviction and preserves strict ownership-loss denial. The real card-intent
path also allows that paired BLE object before metadata acknowledgement; all
non-BLE actions still require owner registration. Enhanced the existing native
case to require a real card intent as well as one fake-radio FIRE, no registration
and no metadata retry. This source fix still needs its actual Apple native run.


## Authenticated native camera video — current source awaiting Apple

CameraStream now routes authenticated HLS/MP4/MOV/M4V through a per-visible-camera
loopback HTTP bridge, then the existing AVPlayer/VideoPlayer. It uses public
Network and URLSession APIs; no unsupported AVURLAssetHTTPHeaderFieldsKey option.
The listener binds 127.0.0.1, accepts only loopback peers and read requests, checks
Host plus an unpredictable session capability, and resolves only authenticated
encrypted same-origin resource URLs minted by that bridge. Remote URL/query tokens
and auth headers do not appear in player URLs. HLS variants, segments and URI
attributes (keys/audio/subtitles/maps) are rewritten; foreign or non-HTTP resources
are rejected. Range/Content-Range and bounded-buffer streaming support progressive
video without loading a whole recording into memory. Cookies and remote response
headers other than constrained media metadata never reach the local client.
Redirects use the same camera-origin boundary; stop/background removes the bridge,
connections and URLSession work. Inline URL credentials become Basic headers and
are removed from request/player addresses. Explicit configured Authorization wins.

Actual Linux core239 zero (4 new parser/URL cases), Swift parse/diff pass. Three
hosted SOURCE tests exercise the real loopback listener with isolated remote HTTP
fixtures: HLS-to-segment auth, rejection of foreign/unknown resources, and MP4 range/
stop behavior. Expected latest hosted140 not yet Apple-compiled or executed. No
actual remote camera or physical iPhone video/decoder acceptance was performed.
RTSP/RTMP/DASH/unsupported native codecs and DRM remain unsupported in this source;
this does not claim every Android video codec is implemented. No new product
screenshot is represented by these transport tests.

API deployment read-only check: https://entrixy.com/api/meta.php returns HTTP200
with v1 and expected websocket/delegation metadata; /api/pwa_login.php returns
HTTP404. The optional account sign-in path cannot be claimed live-working until
that server-side Android endpoint is restored/verified. No account credentials
or mutations were sent in the check.


Public API references for video loader choice: Apple engineer explicitly notes
that AVURLAssetHTTPHeaderFieldsKey is unsupported:
https://developer.apple.com/forums/thread/671139 . Listener binding/acceptance:
https://developer.apple.com/documentation/network/nwparameters/requiredlocalendpoint
and https://developer.apple.com/documentation/network/nwlistener/newconnectionhandler .


## Actual follow-up evidence and additional-source test correction

Publicd1d121b/native6fef9d0 run44119185836/job134165513442: Apple235 core,
Debug, Release/isolation passed; hosted137 executed with three assertions in two
cases failing. Two are the already-fixed paired-owner-before-registration case
(fixc19a8a6 was intentionally absent from that snapshot). The third was the new
additional-source test fixture returning a single global invitation list for two
different source keys; the first part consequently saw the second part's rights.
Corrected the recording API to isolate invitation/child state by signing identity
in that test, without changing assertions or production reconciliation. All five
new sound/export/restore cases, actual imported PIN policy, both Android migration
cases and explicit per-object ACL bounds passed in this exact Apple run. A full
native pass still requires the corrected complete source run; these are individual
case results, not a green-suite claim. The separate UI result for that source is recorded below.


Latest source also bounds expanded HLS output to 4 MiB, resource expansion count
and individual opaque URLs, in addition to the 1 MiB source limit; a malicious
short playlist cannot allocate an unbounded rewritten body. Local239 checkpoint
was followed by actual Linux240 zero at16:27:27UTC with the expansion-bound case.
Owned camera views stop exposing a context on known ownership loss. The loopback
peer check includes IPv4-mapped IPv6 loopback; remote non-loopback peers remain
rejected. All latest Swift parse/diff checks pass; Apple SDK/runtime still pending.


A separate ci/ui-review-arm branch selects macOS15 Apple Silicon for the same UI
assertions. Earlier catalogue UI had passed on ARM after Intel Accessibility setup
failed; the present Intel UI run is retained for its real outcome. This is an
alternate runner, not changed assertions or a capture rerun. Ordinary functional
branches still use Intel Debug/Release/native. Do not infer an ARM pass from the
old catalogue source; the new exact-source run is tracked separately.


## Apple functional result and UI corrections — 17 November, 16:46 UTC

Native fe9e8e1 / public76276e70ef82bb651f2f9cb87fb8b08746c0e8e6,
[run44126465550](https://github.com/entrixy/ios-build./actions/runs/44126465550),
job134191517562 actually passed Apple240 core, Debug/test bundles,
Release/isolation and 140 hosted native tests (37.815 seconds, zero failures).
Both paired-owner-before-HTTP-registration and additional-source lost-reply
regressions passed. All three CameraVideoProxy tests passed with the real local
listener and isolated remote responses. This is transport verification, not proof
of actual camera decoding or physical controller/device acceptance.
The older c19-only run44120544060 ended cancelled, not passed.

Separate UI run44119347879/job134166101257 on publicd1d121b/native6fef9d0
actually executed 14 tests: nine passed, five failed (1041.5 seconds). Unlike the
historical Intel setup failure, this runner successfully started Accessibility
and executed tests. Nine passes include received-passing and server form routes.
Failed hierarchy inspection identified: an ancestor Section identifier overwrote
four object-type button IDs; a Settings label matched both row and bottom tab;
the avatar tap did not open its picker; and the code test targeted a labelled
switch row rather than its nested UISwitch. Changes move the ancestor ID to its
header, give object edit/avatar controls scoped IDs and an explicit 56pt avatar
hit area, and target the real switch in the test. Existing order, size, all eight
presets, upload/cancel and wrong/correct-code assertions remain. These changes
have syntax/diff checks; their actual UI runtime is pending. No claim that the
avatar change has already resolved the hit issue.

UI failure attachment export now retains teardown keepAlways PNGs as well as
issue attachments; the old --only-failures flag omitted actual screenshots.
The downloaded old diagnostics contain hierarchies only, so no visual acceptance
is inferred from them. No new product screenshot batch or website update occurred.


## Compact card confirmation and PIN — follow-up source, Apple pending

Read Android ActionCard.kt runAuthThenCall/confirmOpen and the complete CodeGate.kt
before this change. Manual owner and guest card taps now request one root-level
ActionPrompt with the original frozen intent. ActionConfirmation uses the common
centered AppDialogSurface: object title, confirmation text or code fields, and
equal filled Cancel/action controls. Code setup uses the same Code Entrixy labels
and warning as Android/settings. No logo, navigation header or sheet footer is
added to these dialogs. Biometrics retains the existing platform authentication.
The original per-intent PIN/biometry, lockout, expiry, policy/direction checks and
execute guards remain. Setup continues to require authenticating the action after
saving a new code, preserving the existing iOS authority behavior.

Underlying root controls are hidden from accessibility while the dialog is open.
Foreground automation consumes but does not execute an arrival while a card
dialog is open. Background clears the in-memory prompt; asynchronous completion
checks the same prompt ID and foreground authority before performing the action.
The prompt and typed code are never added to SavedState. Capture scenarios use
the actual root presenter rather than a separate capture-only sheet.

Swift frontend syntax and diff checks pass; these do not prove Apple typing or
layout. One new hosted SOURCE test checks background invalidation/no command/
no restored prompt. One UI SOURCE case checks actual card -> compact confirmation
and code setup -> Cancel -> same Control tab, with all tabs restored. Its two
routes do not resume live transports; telephone handoff is a recording false
closure. Expected source counts now native141/UI15, pending actual execution.
No new screenshots or website publication. Automatic triggers that require
confirmation/authentication still consume without opening a prompt; this remaining
runtime path is explicitly not declared implemented by the manual dialog change.


## Foreground automatic confirmation/authentication — follow-up source

Android ActionCard.runAuthThenCall uses the same confirmation/CodeGate for manual
and automatic arrivals. Automatic foreground arrivals now retain their frozen
intent in the same ActionPrompt rather than silently consuming a gated trigger.
No HTTP/BLE command or journal action is produced by opening the dialog. A single
explicit approval consumes the presented prompt before dispatch; direct execution
of an automatic gated intent without that approval is rejected. Existing PIN or
biometric authorization must still match that exact intent. An already-present
modal prevents another trigger from replacing it. Cancellation consumes the
arrival/latch, removes its permit and cannot reopen from the same evidence.

Proofs are fresh within two seconds at proposal. While the matching dialog or its
single execution owns the evidence, the maximum is thirty seconds; current policy,
conditions and foreground authority are rechecked on authentication, dispatch and
late socket challenge/BLE stages as before. Old/changed evidence cannot be turned
into a manual command. Route triggers retain open-only direction. Background clears
both pending/executing prompt state and all automatic permits; no prompt is saved
or restored. No new background mode or OS permission is claimed by this change.

Five new hosted SOURCE cases cover owner confirm/exactly once, cancellation,
wrong/correct PIN, expiry/storage/background/policy changes before sending, and
received guest confirm/PIN plus duplicate challenge binding. Existing automatic
storage-failure, force/condition and no-replay tests remain. Syntax/diff checks
pass; Apple execution of latest expected native146 is pending. Core unchanged240;
UI source15 still awaits its exact-source runtime result. The previous manual-only
limitation above is historical; this section supersedes that source boundary.


## Factory claim links — source follow-up, Apple pending

Read Android MainActivity.handleInviteIntent claim branch and SettingsScreen
pendingClaim/AddObjectSheet targetHost handling before implementation. DeviceClaimLink
recognizes entrixy://claim?c= and HTTPS /claim URLs, normalizes the Android hexadecimal
code and opens the existing AddOwnerObjectScreen in device/claim mode. HTTPS keeps
the manufacturer origin/port; custom scheme uses the selected server. Query h
cannot move a factory claim to another host. Duplicated c, credentials/fragments,
invalid schemes, empty/non-ASCII hex and excessive input are rejected. The form
shows its server, keeps normal type order and does not register/claim until Save.
Switching away from factory-claim mode uses the ordinary selected server, matching
Android. After switching to new device creation, saved device credentials are
shown through the existing sheet. Cancel preserves the empty profile.

The existing Save now freezes the destination before awaiting registration and
keeps fields disabled during owner work. Existing durable registration/object
claim behavior is reused, with no extra automatic mutation or retry. Five new
core tests passed within actual Linux245/zero at17:07:10UTC. Swift frontend parse
and diff checks pass; one additional UI SOURCE case covers the real pendingURL
route, prefilled code/origin and cancellation. Expected UI16, native146 unchanged.
Apple typing/runtime of this follow-up remains pending. No manufacturer device
or actual server claim was used. Custom scheme is registered; HTTPS universal
link entitlement/AASA association still requires the release team's real identity
and remains a separate release criterion, not proven by direct pendingURL testing.


## Actual compact-dialog UI result and avatar accessibility correction

ARM run44131318837/job134208842769, publicceca452/nativea70c33a, actually passed
Apple240 core and Debug test build, then executed all 15 UI tests: fourteen passed,
one failed (339.345 seconds). Compact card confirmation/code setup cancellation,
wrong-code entry-lock, Android type order/default/BLE creation, exact object editor,
passing and server routes all passed. The remaining avatar test failed before a
tap: adding accessibilityElement(children:.ignore) had exposed its labelled/ID
wrapper as Other with an anonymous Button child, so app.buttons could not select
it. Removed that wrapper modifier while retaining the explicit 56pt frame/hit
shape and label/identifier on the actual Button. Existing size/preset/upload/cancel
assertions remain. This correction is syntax-checked, actual retest pending.

Failure export now actually retained the native PNG and screen recording. The
private PNG was inspected; it shows the original object row and avatar, not an
opened picker. It is diagnostic evidence, not a replacement gallery capture.
No new product batch/site publication has occurred.


Intel UI run44130029382/job134204239696 on public7895b08/nativebf724a7
failed before any UI test began: Core240 and Debug passed, but CoreSimulator cold
boot stalled; bounded recovery also timed out creating a replacement. This is
not a new UI assertion result. No retry of that same stale source was requested.
The latest ARM review is run44134044615/job134218585629 on public7630c62/native
d1f89b7, queued at17:15UTC. All309 app/core/test/project/Package files were actually
byte-compared with no differences (private current-ui-equivalence.json). Expected
core245/UI16 are source counts for this queued run, not a passing result.


## Actual automatic-gate result and incoming proof fixture correction

Public64094ad/native6b42489 run44132343577/job134212519533 passed Apple240
core, Debug and Release/isolation, then executed146 hosted tests with ONE failure.
All four new owner-gate cases passed (confirm once/cancel/PIN and expired/storage/
background/changed policy), together with existing runtime/BLE/transaction cases.
New guest-gate case failed unwrapping the proposed prompt: its test constructed
proofs from the raw wire template, whereas the real coordinator evaluates the
received three-way effective template with added owner radius/minimum bounds.
These unequal templates were correctly rejected. The fixture now evaluates the
actual scoped automationContext template and asserts geo/confirm/auth survived
the merge before evaluating evidence. Production equality guards, PIN assertions,
no-send-before-approval and duplicate challenge assertions remain unchanged.
Syntax/diff pass; the complete corrected suite still needs a fresh actual result.


## Owned BLE information — current follow-up source

Read SettingsScreen.kt owned BLE row (Settings, AutoMode, Info, Delete), its full
infoBleId dialog and BleScanReceiver/BleCrypto metadata decoding before this change.
The owned BLE expanded row now includes Info after automation, before deletion.
The common compact dialog uses the object's label and shows battery, hardware,
firmware nibbles, sleep, status flags and actual observation age. With no verified
metadata it shows Android's no-data message, never a fabricated 0% or firmware.
No info action is added to guest BLE rows: the encrypted telemetry is owner-only.

BLEDeviceInformation authenticates/decrypts the existing v3/v4 optional fields;
legacy16/17-byte advertisements cannot create readings. The actual passive owner
observer populates an in-memory scoped (host/object) cache only after matching
DID/owner/state validation; no scan/FIRE/pair/register operation is performed by
opening Info. Cache entries for removed/lost/mismatched objects are discarded on
owner save. No telemetry enters SavedState/backups or becomes proximity authority.
Background closes the dialog; an open modal cannot trigger another automatic
command. The shared button styles, original avatars and flat navigation remain.

Three new independent frozen-vector tests passed within actual Linux248/zero
(log ble-information-core.log); complete Swift frontend parse and diff checks pass.
One UI SOURCE case covers Info -> no data -> Close -> same row/tabs without a
radio session. Latest expected UI17, native146 unchanged; Apple typing/runtime
of these new fields still pending. No physical controller or product capture used.


AutomationEditor's local code-setup flow now uses the same compact AppDialogSurface
instead of opening another full-height navigation form. Shared filled Cancel/Save,
field labels, digit filtering and Android forgotten-code warning are preserved;
cancel still invokes the existing finishCodeSetup policy/force guards. Typed code
clears on leaving/scene inactivity; saving still uses the protected model API.
Syntax/diff checks pass, actual Apple/layout verification is pending. No new core
behavior or extra runtime test is claimed by this presentation-only follow-up.


## Actual complete sixteen-case UI pass

Public7630c622512eea3b33f0458f6010cb0e95ffc57e/native d1f89b7,
[run44134044615](https://github.com/entrixy/ios-build./actions/runs/44134044615),
job134218585629 actually passed Apple245 core, Debug test build and all16 UI cases
(442.107 seconds, zero failures). Avatar Button selection/tap, all eight original
presets, upload-button presence and cancellation passed. Real photo selection or
upload was not performed by that test. Factory claim code/origin/cancel and compact
card confirmation/code setup also passed. No new product PNG batch was generated.
This source predates BLE Information/late dialog completion cleanup/code setup
inside AutomationEditor. A latest-source UI17 follow-up is required for those.

The earlier functional publicbbad08b/nativea70c33a additionally completed core240,
Debug, Release/isolation and all141 hosted native tests (55.706 seconds, zero
failures) in run44131228346/job134208518844. Do not combine the two source results
into a claim that the newest entire app has passed every check.


## Later complete functional passes

Publicb0a88bb5c6bf6d6a4fad33d92a8f979fc13b9d1e/native384132a,
run44135507897/job134223819556 ACTUALSUCCESS: Apple245 core, Debug,
Release/isolation and146 hosted tests (51.131s, zero failures). The corrected
received guest confirm/PIN/duplicate-challenge case passed. Publicb10f1d7b25e8c51344aae6e5bd3f0b0ede452fed/nativefd82582,
run44137608867/job134231365669 then ACTUALLYPASSED Apple248 core, Debug,
Release/isolation and146 hosted tests (24.936s, zero failures), including owner
BLE information compilation. It predates the compact automation code-setup change.
UI17 on public88d3652/native d876de8 remains pending in run44138620969.

## Network privacy foundation — not an enabled product feature yet

Read Android NetRoute.kt, Prefs blocked_wifi/blocked_wifi_g_* encoding, Vault's
net_block and all current Core OwnerAPI/GuestAPI HTTP/WSS creation points. Added
PrivacyNetwork with exact encrypted wire keys s/b and case-insensitive SSID OR
BSSID matching; unknown Wi-Fi fails closed. ServerNetworkDecision separates system,
explicitly authorized cellular and blocked routes. iOS16's unavailable constrained
URLSession proxy configuration must never silently become a default connection
when restrictions exist. A bounded authenticated CONNECT parser preserves opaque
TLS bytes and rejects body/header smuggling, invalid authorities and missing caps.
ServerSessionPolicy is a locked composition hook for the TWO Core server clients;
it is currently uninstalled/no-op. Camera/phone-webhook sessions are not changed.

Actual Linux259 zero at17:53:24UTC, including11 new policy/parser cases; Swift all
sources parse and diff pass. THESE ARE FOUNDATIONS ONLY: no app proxy, persistence,
privacy UI or encrypted-bundle propagation is enabled. Existing net_block guards
remain unchanged and must not be relaxed until the complete route is enforced.
No new cellular connection, report upload, screenshot or server mutation occurred.

Apple primary references consulted for the planned public transport boundary:
https://developer.apple.com/documentation/network/proxyconfiguration
https://developer.apple.com/documentation/foundation/urlsessionconfiguration/proxyconfigurations
https://developer.apple.com/documentation/network/nwparameters/requiredinterfacetype
Apple DocC platform metadata confirms proxy configuration is iOS17+, not iOS16.
ProxyConfiguration.allowFailover defaults false; maintain that boundary. HTTPS TLS
must remain with URLSession through an opaque local CONNECT tunnel, never a private
AVURLAsset/session header key or TLS certificate bypass. Device/cellular/roaming
behavior is still unverified; do not imply an available public roaming detector.


Network privacy follow-up SOURCE: ServerPrivacyProxy now implements an isolated,
authenticated loopback CONNECT transport with public ProxyConfiguration on iOS17.
It requires TCP cellular on a cellular decision and prohibits Wi-Fi/wired fallback;
URLSession keeps end-to-end TLS/certificate validation. Auth/policy rejection opens
no upstream. Existing default-interface tunnels close when a rule tightens. Bounded
headers/connections/32KiB buffers, idle/connect deadlines and TCP half-closes apply;
no HTTP body/secret logging or interception, no retry on failure. Five hosted
SOURCE tests exercise real loopback byte forwarding, invalid capability/deny,
closing existing normal tunnels, no fallback on refused cellular and actual public
URLSession proxy authentication before TLS failure against a deliberately non-TLS
echo fixture. These use injected LOOPBACK connectors, never a real cellular radio.
They are not physical-cellular/DNS/roaming/WSS acceptance. Swift parse/diff pass;
SDK typing/runtime pending. The component remains UNWIRED in the live app: no
legacy net_block guard was relaxed, no privacy setting falsely enabled. Next
required work is protected own/received rules, encrypted-bundle propagation, live
session lifecycle/guard composition (including iOS16 fail-closed), and matching UI.
Expected next hosted151/core259 are SOURCE counts pending Apple.


Session-lifecycle follow-up SOURCE: both server Core clients now use a locked
ServerHTTPSession holder. Installing/changing policy rebuilds sessions and cancels
old HTTP/WSS tasks without resubmission. Requests take the session before checking
the latest authorization, so a later change cancels that retained session rather
than granting a newly replaced one from a stale check. HTTP, metadata, initial
snapshot and both live sockets pass the same preflight. Three new actual Linux
Core cases verify no request under deny, the same client after removal, WSS/initial
snapshot preflight, and cancellation of a held request with no duplicate send.
Complete Linux262 zero (server-session-policy-core.log), syntax/diff pass. The
live app still installs no routing policy; persistence/UI/bundle propagation and
full Apple execution of this follow-up remain pending. Legacy net_block rejection
has not been relaxed.


## Actual later UI17 result and rename synchronization follow-up

Public88d365270bf993f63442d3431915ea1ae89d65c3/native d876de8,
run44138620969/job134234929889 passed Apple248 core/Debug, then executed17 UI
cases:16passed/1failed (509.845s). Owned BLE Info no-data/close, avatar, compact
confirmation/PIN and factory claim all actually passed. The old rename/hide case
failed after Save when tapping Control: XCTest reported an unhittable {-1,-1}
point and the final hierarchy still showed the original Settings row. This same
case had passed on the earlier sixteen-case source. It did not assert the typed
value or saved label before switching tabs, so this is not proof of a storage bug.

Received-object name input now disables autocorrection, offers Done and dismisses
the keyboard on submission/save; line breaks are stripped consistently with owner
names. The UI test asserts exact Yard input, waits for that actual row label and
all bottom-tab hit targets before switching, then retains all existing Control/
hide/key-preservation checks. No assertion removed and no blind repeat of the
same scenario. Source parse/diff pass; actual retest and diagnostic PNG inspection
are pending. New product screenshot batch/gallery still unchanged.


Isolated proxy publicb48ee49/nativef008db3 run44143833623/job134253459314
actually passed Apple259 core, then Debug test-bundle compilation failed at
ServerPrivacyProxyTests.swift156: an await was inside XCTAssertTrue's synchronous
autoclosure. Moved only the awaited response into a local variable before the
same assertion. No native proxy cases ran in that attempt; retry on corrected
complete source is still required. The public API transport remains uninstalled.
The UI17 failure PNG was actually inspected privately: original guest Settings
row/name/expanded actions, with no keyboard or rename form. It does not identify
whether typing or commit failed. The new exact input/saved-row assertions pinpoint
that boundary; the name draft also initializes once and freezes before resigning
focus, so presentation updates cannot overwrite an active edit.


### Network policy material — 17 November, follow-up

Owner network rules now enter only the encrypted root guest bundle; child bundles
retain their parent's restrictions. Explicit empty rules remove the owner's list;
legacy nil leaves an existing protected list intact. A changed list queues a fresh
bundle after reconciliation without modifying a persisted in-flight ciphertext or
signing identity. Android own/guest lists are decoded by their original scopes,
and original backup bytes remain unchanged. Import merging preserves this phone's
cellular consent and cannot acquire it from another device.

Linux266 core tests passed, including four new scope/merge/inheritance/in-flight
cases (privacy-bundle-verified.log). The first new encrypted-request fixture lacked
a pending operation and failed; setting that test's real keyEdit operation fixed
the fixture without weakening guards. Live storage/UI/routing integration is still
pending: the proxy remains uninstalled and net_block unsupported barriers intact.

Corrected proxy/session source c5e4a05, publicd4128a9/a2960e9, is running in
Apple runs44146144027 and44146147004. Core/Debug passed in both and Release/isolation
passed in the functional job; native151 and UI17 execution are still pending.


### Native privacy persistence / actual UI17 — 17 November

SavedState, SavedGuest, pending Android recipients and iOS/Android backup adapters
now retain scoped privacy lists. Export strips only local cellular authorization.
Owner backup merge unions restrictions and queues changed bundles without changing
sent ciphertext/identity; failed final activation rolls preferences back with the
restore plan. Two new hosted source cases cover protected-state/export and failed
activation/retry; Android migration cases now assert own/guest/pending scopes.
Linux267 core and all Swift frontend syntax checks passed. Hosted SDK/runtime
verification of this persistence step is pending. The proxy remains uninstalled;
no net_block guard was removed and no new privacy controls are exposed yet.

UI retest nativec5e4a05/publica2960e9, run44146147004/job134261681030, actually
passed Apple262 core, Debug and ALL17 UI cases (432.439s). Exact Yard input, saved
row, Control and hiding-with-key-preservation passed; new owner BLEInfo passed too.
This is not actual photo upload/hardware/release/full screenshot batch evidence.


### First actual proxy runtime results and compatibility correction

Publicd4128a9/nativec5e4a05 run44146144027/job134261671566 actually passed
Apple262 core, Debug and Release/isolation; hosted151 ran with3 assertions failing
in TWO new proxy cases (31.447s). Existing146 passed. Three new cases passed:
authenticated opaque bytes, missing capability/blocked policy and closing an
existing default tunnel. A refused upstream remained waiting beyond the client's
10s deadline; URLSession's actual CONNECT got local400 before any upstream attempt.
Artifact upload also failed with GitHub service request timeouts.

The proxy now rejects waiting upstreams promptly with502, without retry/fallback.
Parser accepts HTTP1.0 legacy CONNECT and equivalent Host default443, still requiring
explicit target port, matching authority, bounded headers, capability and no body.
Added a Core authority case; Linux268 zero. Native test assertions remain intact.
A DEBUG/simulator-only structural rejection diagnostic retains only HTTP version
and header field names, no target or credential. The exact rejected Apple header
shape was not available in the failed run; actual retest must confirm the change.
The transport remains uninstalled; no released runtime behavior changed.


### Protected routing composition source — not attached to live root yet

ServerPrivacyRouter installs a closed authorization gate, configures/reset existing
server clients through the opaque proxy and cancels old sessions on rule changes.
iOS16 rejects server traffic with restrictions. On iOS17, because the public TCP
interface selector does not bind one SSID across roaming, the conservative choice
is to require cellular for ALL server traffic while any home restriction exists.
Fallback from Wi-Fi requires this phone's explicit consent; an already cellular
system path keeps using cellular. This platform difference must be visible in the
System section before enabling controls. Real radio/DNS/VPN/roaming acceptance
is still required; loopback tests do not prove physical interface behavior.

AppModel optionally composes this router, retains newly authenticated guest rules
before snapshot/live traffic and includes protected pending-restore rules before
claims. A failed rule write keeps a restrictive in-memory latch across unrelated
saves. Protected network edits atomically update preferences and owner bundle
refresh queues. Legacy cached BLE metadata supplies missing local rule records.
The shared metadata capability defaults OFF; only an installed guarded transport
can accept strictly validated net_block metadata. Offline BLE retains confirm/PIN
and expiry checks even when that boundary rejects every server request.

Linux270 zero, including two new boundary/offline BLE cases; full Swift parse and
diff pass. Two new hosted router source cases cover the actual pre-existing
OwnerAPI adopting a required-cellular route with no fallback and stop denying
requests before any connection. Apple typing/execution is still pending.
LiveAppRoot has NOT injected the router yet; no new privacy UI is exposed.


### Missing server account contract restored — site875d2b6

The endpoint used by BOTH Android and iOS, api/pwa_login.php, was absent. It now
uses the existing password hash/email confirmation/session-version model and
website login throttle, returning the existing token contract with a five-minute
uid/sv/exp token. No browser session/cookie, account registration, device linking
or DB mutation is performed by this endpoint. Request JSON/input sizes are bounded
and failures disclose no token/credential/exception text. No iOS wire change.

PHP syntax, isolated login contract checks and existing guest signature tests
passed. Live HTTPS405/400/401 for method/invalid/unknown account passed with no
Set-Cookie and no-store. No real account was authenticated or changed; successful
real login/link remains a device/integration acceptance item. Site gallery and
all unrelated pending web sources were preserved. This closes the known404 gap
without claiming complete production account acceptance.


### Routing completeness follow-up and native ARM check

Server company logos now use the same guarded/resettable ServerHTTPSession as
HTTP/WSS APIs, with their existing bounded image stream and redirect rejection.
Camera and direct phone-webhook sessions stay independent. The stopped-router
hosted case now also asserts no outbound logo connection. Pending restore rules
are covered before any move/claim; an injected guest snapshot test covers failed
rule persistence staying restricted across an unrelated save, then authoritative
removal. These additional hosted source checks remain pending on Apple.

Legacy Android backups distinguish absent blocked_wifi from explicit empty.
Merging an unknown legacy owner list with an imported empty list preserves
restrictions already inside encrypted keys; toggling local cellular consent
does not clear owner restrictions or rewrite guest bundles. Recovered Android
keys receive a queued current-list refresh when an explicit owner list differs,
without changing existing ciphertext before publish. Invalid network rows stay
in verification-required recovery material. Linux271 passed with the additional
legacy merge case; source syntax/diff and all7 Product tables (919 keys) pass.

Native System home-network section source follows Android after servers, shares
filled controls/compact root confirmation, local permission and seven translations.
It remains HIDDEN without an injected router; LiveAppRoot does not inject one yet.
Public API iOS17-only conservative cellular routing and iOS16 fail-closed behavior
are stated in the UI; physical radio/DNS/VPN/roaming acceptance still pending.

Two Intel native runs remained in native-test preparation/execution for over8min.
Added ci/native-review-arm on the same macos15 ARM runner that passed UI17, to
execute complete Core/Debug/Release/isolation/hosted checks on current composition.
Existing runs are not cancelled. No product screenshot batch/publication.


### Actual proxy green and live composition source

Native633005e/publicbe2be6a run44150323650/job134276531601 ACTUALSUCCESS:
Apple268 core, Debug/test bundles, Release/isolation and153 hosted native tests
(134.464s zero). All five proxy cases passed, including actual URLSession CONNECT
authentication with TLS rejection retained and unavailable-cellular no fallback.
Both privacy backup state cases passed. This source predates router composition.
Native1927187/public04154a7 run44152754848/job134285231958 ACTUALSUCCESS:
Apple270 core, Debug and ALL17 UI (499.154s zero), still before home-network UI.

LiveAppRoot now composes the router: a closed gate is installed during router
initialization, before model use; start/reset finishes before resume. Router
construction stays INSIDE StateObject's deferred initializer so rebuilding the
Scene cannot replace the retained model's global gate. DEBUG hosted unit tests
use a blank host; explicit UI/capture routes keep their existing isolated models.
Normal live empty startup/theme rebuild and home-network consent/delete/key
preservation are two new UI SOURCE cases (19 total), not yet executed. Permission
button has its own clear list section, avoiding a grouped background fragment.

The route also rejects known blocked policies synchronously before any HTTP/WSS
request. Only the typed local preflight failure can reset a registration marked
sent in THIS invocation to prepared; an old sent reservation or a remote server
error cannot. No automatic retry/new master/physical command. Added a hosted
source case for explicit retry preserving the master and refusing an ambiguous
server error with the same text. Added actual WebSocket proxy/TLS source coverage
alongside HTTP. All current Swift syntax passes; local Linux271 and7 Product
tables920 keys validated. Full current Apple typing/native/UI19 still pending.
Real cellular/DNS/Wi-Fi roaming/VPN/device/signing and remaining full-port features
are not proven by loopback; no screenshot batch or gallery update has occurred.


## 19 November: continue full port — diagnostics and actual live-routing result

Latest previous source native2556eaf/public3a13b4a run44157787988/job134303089647
actually passed Apple271 core, Debug/test bundles, Release/isolation and159 hosted
checks (20.712s zero), including WebSocket proxy/TLS and local-only registration
preflight retry preserving the reserved master. UI19 public9ee3f34/run44157583649
was CANCELLED IN QUEUE with no test steps; no UI19 execution is claimed.

Read Android System crash switch before theme, Diagnostics.kt, trusted Api report
endpoint, Help seven-tap unlock and actual developer manual-send/off controls.
The manual send is inside Android's hidden developer section, not an invented
normal System control. Native source follows those placements. MetricKit collects
only crash stack summaries after an explicit persisted consent; old reporting
periods are ignored. Stack data is rebuilt from known structural fields; paths,
exception text, symbols and arbitrary fields are dropped. Reports contain only
counts, versions and fixed technical error codes, no object names/server addresses/
coordinates/access identity or action history. Report IDs are per-report, not a
persistent installation identifier. Core uses the trusted entrixy.com report
contract through the same guarded/resettable no-cookie/no-redirect server session.

Consent/queue/technical events live in a bounded protected file excluded from
backups. Failed opt-out persistence pauses automatic sending in memory; successful
opt-out purges queued crashes. A lost upload reply preserves the same report and
does not spin a retry loop. Backgrounding cancels upload and suppresses late UI
completion. First-launch consent uses the shared compact dialog; task visibility
is centralized so automatic actions cannot replace any active root dialog.
Seven version taps in Help enable manual log send/off in System as Android.

Linux276 passed (five new sanitization/contract/preflight cases); all Swift source
syntax, diff and7 Product tables926 keys passed. Four new hosted flow SOURCE cases
cover default-off/manual/no access mutation, consent-before-send, failed opt-out
and retained lost-reply/unreadable consent. One new UI SOURCE case covers consent/
seven taps/manual ACK/off, and ordinary startup handles first-launch consent.
Expected current UI20/native163 are source counts ONLY, pending Xcode execution.
No report was actually posted to the production server by tools. Real MetricKit
delivery needs a physical device; no simulator/hardware/signing claim is made.

Primary Apple references: https://developer.apple.com/documentation/metrickit/mxmetricmanagersubscriber
https://developer.apple.com/documentation/metrickit/mxcallstacktree/jsonrepresentation()
Legacy MX API supports the deployment target and installed Xcode26.3; delivery
is OS scheduled. Remaining OS readiness/background/widget/device/release and
the final complete native capture batch are still active work.


### Permission readiness and diagnostic decline follow-up

Read the full Android permission card before Settings subtabs. Native PhoneReadiness
now adapts actual per-object requirements: current/precise location for geo and
connected-Wi-Fi rules, Bluetooth for BLE objects, notifications for configured
notify reactions. A profile without these features asks for none. Always location
is deliberately not requested by the still-foreground automation runtime; the
portable readiness model distinguishes it for the future background integration.
No Android OEM/autostart/battery-whitelist controls are invented on iOS.

Reading permission state never creates a Bluetooth manager. Only a button tap can
request Bluetooth authorization, location or notifications; denied/precision cases
open public iPhone app settings. The card sits above Settings subtabs like Android,
uses the existing common filled controls and does not replace object status circles.
All six native permission purpose strings are now localized into the seven product
languages. Apple accuracyAuthorization and CBManager.authorization docs consulted.

Linux279 passed (three new readiness truth-table cases), all Swift syntax/diff and
Product933/InfoPlist6-key tables in seven languages pass. Native permission UI/OS
callbacks still need Apple/device acceptance. The first crash-consent Not Now now
closes even if diagnostic storage alone cannot save, pauses auto sending and
suppresses reoffering that session; a fifth hosted source case verifies access
stays usable. Current diagnostic runs exclude this follow-up and remain pending.
No actual production diagnostic report was uploaded and no new product screenshots.
