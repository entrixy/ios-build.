# Entrixy for iOS — work in progress

Native iOS port of the full Android client, not an expansion of Entrixy Open.
The existing full client defines expected behavior and the server wire formats.
This repository is private working source; no new distribution license is assigned.

## Current implementation and verification — 19 November 2026

The current baseline, remaining work and evidence are maintained in
[CURRENT_STATUS.md](docs/CURRENT_STATUS.md); use it before the historical notes
below. The autonomous batch workflow is [AUTONOMOUS_WORK.md](docs/AUTONOMOUS_WORK.md).

Native ec2c81f/public487b2f6, [CI44521810979](https://github.com/entrixy/ios-build./actions/runs/44521810979),
passed Apple312core,191hosted,27UI, Debug/Release/privacy/isolation and unsigned
physical-iPhone app/widget archive. All56 original screenshots were reviewed and
published in the [gallery](https://entrixy.com/ios-design.php), replacing19older
frames. Signing, real device/interoperability acceptance and Store gates remain
open. Backend APNs source is verified in isolation but unconfigured for real delivery.

The following dated package notes are historical, not the current status.

### Previous package evidence

Latest completed package: native6625b7e/public91491ea,
[run44493224665](https://github.com/entrixy/ios-build./actions/runs/44493224665).
Apple308core, Debug app/widget/test bundles, Release/privacy/isolation and an
unsigned physical-iPhone Release archive passed. Hosted184of185 and UI24of26;
40of45 original PNGs, overall failure. The old delegated-revoke assertion,
promotion identifier and diagnostic AX failures are recorded in
[the current evidence](docs/FUNCTIONAL_PORT.md).

Next complete package native94efd48/public506cb4d,
[run44499802532](https://github.com/entrixy/ios-build./actions/runs/44499802532),
expects308core/185hosted/27UI/56distinct native PNGs. Shared action sizing and
expanded object-rule/map/camera/guest/device inspection are included. Syntax and
six pipeline contracts passed; Apple runtime remains pending. No failed/partial
batch has replaced the19old gallery frames. Signing, hardware, interoperability,
APNs, TestFlight and final Store material remain incomplete.

### Earlier implementation and evidence notes

The latest source also adds Android-compatible object-key rotation and the Home
promotion catalogue. Linux308 core tests passed. The next whole Apple batch
expects185 hosted tests,26 UI scenarios and45 original checkpoint PNGs; these
new additions have NOT yet passed Apple SDK/runtime. Source and boundaries are
recorded in [FUNCTIONAL_PORT.md](docs/FUNCTIONAL_PORT.md). The current Apple
run44486818161/publicfc190f0 verifies the preceding9932f07 snapshot, excluding
rotation/promotions; do not attribute its results to the latest source.

The full Android port remains the active task. The gallery still contains the old
19-frame catalogue; a new full native screenshot batch follows functional completion.
Latest coherent Apple batch: native `98d4676`, public `3b806d7`,
[run44477923156](https://github.com/entrixy/ios-build./actions/runs/44477923156):
295 core tests, Debug including motion/native-host/widget/test products, Release/
privacy-manifest packaging/isolation and all179 hosted native tests passed. UI25:
24passed, including the incoming-message queue/Close and local key deletion dialog.
Diagnostic consent still timed out reading the accessibility snapshot. A separate
modal host DID NOT resolve that failure. The overall run failed;40/44 original
checkpoint PNGs exported, with four diagnostic states missing. No new gallery
publication or complete visual acceptance is claimed.

Latest build evidence: native `e2d7b01`, public `dc29234`,
[run44482890600](https://github.com/entrixy/ios-build./actions/runs/44482890600)
passed Apple295 core, Debug/test bundles and Release/privacy checks. It ALSO
successfully archived the app and widget for physical iPhone SDK26.2, arm64,
minimum iOS16/17 respectively. The archive is unsigned, fixture-isolated and
privacy manifests are packaged; signing, device testing and upload remain pending.
The simulator's cold boot reported terminal migration failure and its UI service
hung BEFORE any hosted/UI scenario. No179/25/44 runtime result belongs to that run.

UIKit consent labels/buttons with explicit accessibility order now compile and
archive, but their runtime verification remains pending. Simulator appearance is
now prepared inside bounded cold-boot recovery, before any test scenario starts.
Six isolated pipeline contracts cover successful exports and preparation failures.

Further visual followups wait for stable visible geometry before original screen
capture, retain the fixed action footer throughout all compact task dialogs, and
prevent a three-button backup row from hyphenating Save. These were actual defects
found in the prior native PNGs. Gallery preparation validates source/hash/state
coverage and rejects partial or failed runs. No screenshots were retouched.

Background BLE and own local webhooks use short per-object automatic authority and
expiration/cancellation. PIN/confirmation BLE remains manual-only, following Android.
Calls and other foreground-only routes produce a local navigation notification;
persistent background WSS/APNs is absent. Entry/manual/settings guards stay separate.
Independent Core Motion now supports Android's frozen-location warning without
inferring motion from GPS; local295 core tests passed, physical behavior is pending.

CI builds test products once, verifies Release once, then runs hosted and UI cases
in ONE simulator pass with original screenshots at the UI checkpoints. No separate
screen replay or duplicate light/dark variants. The next source expects179 hosted
cases,25 UI scenarios and44 distinct frames. The remaining consent-provider/footer/capture followups
have passed Apple SDK compilation; their runtime/visual proof is pending. Final visual/parity acceptance and gallery
publication remain separate. Gallery preparation refuses partial or failed runs.
The next CI source also archives Release for the physical iPhone SDK, without
signing or an IPA export. It verifies arm64 AND the Mach-O physical iOS platform
(a simulator can also be arm64), app/widget identifiers and privacy manifests,
fixture isolation and absence of provisioning/signatures. Only build evidence is
retained in CI; archive compilation passed in run44482890600. This is not signing,
a physical-device test, TestFlight or an upload-ready build.
Full background/device/release gates and the full Android port remain incomplete.
Detailed scope and evidence: [FUNCTIONAL_PORT.md](docs/FUNCTIONAL_PORT.md).

### Historical catalogue checkpoint — 16 November 2026

[Android structure](docs/ANDROID_STRUCTURE.md) records the full product tree and
all 83 Kotlin files. [iOS structure](docs/IOS_STRUCTURE.md) maps all 62 nodes to
actual integration or explicit gaps. The shared scoped object catalog now drives
Settings and Control, including stable order, expandable actions, durable local
rename/hide and Bluetooth creation through Add Object.

App source `49fb249`; build source `069d20b04319cb97c371ba7b91c59f5533db7cd1`
(native checkpoint `2dc2f7c`, including simulator preparation).
[Apple CI 43932876115](https://github.com/entrixy/ios-build./actions/runs/43932876115)
passed 142 core tests, Debug, Release/fixture isolation, 81 hosted native tests
and capture19. The overall run **failed**: XCTest could not initialize UI testing
because Accessibility timed out; the seven UI cases did not run in that attempt.
[Isolated UI verification](https://github.com/entrixy/ios-build./actions/runs/43941617579)
is separate; the app/build configuration and test assertions match the capture
source byte for byte. The ARM job passed all seven UI tests with zero failures; this verifies only the older catalogue/navigation source.

[The gallery](https://entrixy.com/ios-design.php) now contains 19 reviewed native
product-route captures, one light iPhone 16 frame per state. All PNG source/hashes,
public HTTPS files and gallery interactions were checked. The gallery explicitly
separates reviewed images from pending UI acceptance. Previous 13 frames were removed.

This is a bounded object-structure implementation, not the complete Android port
or an App Store release. Full automation, remaining object/access editors,
background/device/signing checks remain in the parity/readiness documents.
The user requires the functional port before a new screenshot batch. Do not substitute catalogue captures for completed object settings.

The current working source adds the Android object fields, device registration and
credentials, individual automation settings and custom avatars. Core tests pass
on Linux; Apple compilation/runtime of these additions is tracked separately in
[functional port progress](docs/FUNCTIONAL_PORT.md). Foreground automatic execution, durable BLE registry migration and verified passive
BLE proximity are now in source. Scoped JPEG/MJPEG/native video presentation and
original Android event sound settings are also connected. Exact-source Apple
checks are tracked separately; background execution, additional authenticated
video codecs, companies and other remaining product flows are still incomplete.

## Historical milestone notes

The sources/counts and “current” statements below describe earlier milestones;
the checkpoint above and readiness documents are authoritative for today's state.

### Earlier state

Verified implementation source: `2a91220`. It passed 26 core tests with Apple
CryptoKit, nine hosted native tests, the Xcode simulator build, and twelve real
captures (six main screens each on iPhone 11 and 16):
https://github.com/entrixy/ios/actions/runs/41304975510

The current guest flow includes:

- v1 HKDF/Ed25519 guest signatures and AES-256-GCM, checked against frozen vectors;
- invite parsing and per-server identity fingerprints;
- exact-body signed HTTPS requests, redirect rejection and safe binding fallback;
- authenticated foreground WSS updates, reconnection and object metadata decryption,
  including the previous object-key generation during rotation;
- native SwiftUI tabs, search, key management, encrypted avatars and QR/photo imports;
- signed manual network actions, owner confirmation, local PIN/biometric gates,
  and a persistent journal of actual attempts/results (see limitations below);
- device-only Keychain state, persisted before binding. Read/decode failures never
  create a replacement identity. Keychain startup/read/write has now been exercised
  across repeated app launches on fresh iPhone simulators; recovery tests on real
  devices are still pending.

**Initial milestone verification:** 16 XCTest cases passed with Swift 6.0.3 on Linux using Apple's
swift-crypto, including golden signatures, incorrect decryption keys, malformed
invitations, failed binding, loss of a bind response, redirect rejection and old
object keys. App Swift files pass syntax parsing. Initial macOS CI compiled the core and
exercised Apple CryptoKit, revealing that CryptoKit's valid randomized Ed25519
signatures need not equal deterministic signature bytes. Golden vectors remain
unchanged; tests verify published and generated signatures with the frozen public
keys. Actual macOS signatures were also independently verified using PHP/libsodium.
The corrected macOS run passed all 16 tests with Apple CryptoKit and Xcode 16.4
successfully built the iPhone simulator app for source commit `a63bc61`:
https://github.com/entrixy/ios/actions/runs/41280296917
That first run verified compilation only. Later simulator startup/Keychain and
capture results are documented below. Physical-device operation, BLE and TestFlight
remain unverified/unconfigured.

Current source includes owner registration/object management, guest-key issue/edit/
revoke, foreground owner controls, encrypted iOS backups/device migration and the
sender/recipient/owner delegation path. These additions have core protocol checks
on Linux; the current app has NOT yet passed an exact-source Apple build/native
run or screenshot review. Foreground message inbox/compose and delivery/read acknowledgement are also in source.
BLE owner pairing and one-shot pulse control now have native source, but have not passed an Apple build or hardware test. Guest BLE offline control, explicit token renewal and signed revocation delivery also have source/core checks; their Apple/native/hardware execution remains unverified. Automation/background/APNs and Android backup payload import remain incomplete. See `docs/APP_STORE_READINESS.md`
for the separate source and device/release evidence. Unsupported combined/network/time conditions block manual commands;
they are not silently skipped. No real controllers or phone calls were actuated.

`project.yml` generates an actual Xcode app project using XcodeGen. The GitHub
workflow builds a **locally signed simulator app**, which cannot be installed on
an iPhone or sent to TestFlight. Apple signing/TestFlight configuration comes later.

On macOS:

```sh
swift test
brew install xcodegen
xcodegen generate
xcodebuild -project Entrixy.xcodeproj -scheme Entrixy \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build
```

On Linux (protocol core only):

```sh
docker run --rm -v "$PWD:/work" -w /work swift:6.0.3-jammy swift test --jobs 4
```

## Repository and CI access

Source is hosted privately at `git@github.com:entrixy/ios.git` and can be pushed
with the existing SSH identity authenticated as `entrixy`. The separate GitHub
connector is linked to another account; it is not required for source access.

The macOS job retains its normal Actions artifacts and exports a small build
report to the private `ci-results` branch. This allows reading compiler errors
through Git/SSH without exposing an API token. The build job has read-only
permissions; only the Linux reporting job can write repository contents. Reports
are not published for pull-request runs and never include signing credentials.

The workflow produces locally signed simulator builds, not TestFlight releases. No
Apple signing account or paid service subscription has been configured.

## Porting sequence

1. Build and pass the core vectors on macOS; implement signing for WSS and presses,
   invite parsing and sealing. Never alter the vectors to satisfy the port.
2. Keychain identity and encrypted local storage, failure-safe persistence, HTTPS
   transport without credential redirects, device binding and WSS reconnection.
3. Native interface matching the full app's structure; owner objects, guest keys,
   sharing, delegation, revoke, encrypted journal and multi-server operation.
4. CoreBluetooth pairing/opening, expiry/renewal and revocation delivery. Verify
   with real controllers before describing it as compatible.
5. Apple notification/background/location integration. Automatic owner-phone SIM
   calls cannot be copied from Android; explicit dial confirmation is required.
   Never repeat an opening automatically after an ambiguous result.
6. Apple signing, device tests and TestFlight distribution.

## Environment agreed with the user

- No Mac currently available.
- User reported “11 and 16” for available iPhones; confirm iOS versions when
  setting up device builds. Provisional minimum target is iOS 16, not final.
- No Apple Developer Program membership yet. It is not required to write source.
- A local or remote Mac with Xcode is required for app builds. TestFlight requires
  Apple Developer Program membership. Personal-device testing directly with Xcode
  can use a free Apple Account, subject to Apple's provisioning restrictions.
- Do not ask for Apple passwords/2FA codes or purchase/rent services automatically.

Apple references:
https://developer.apple.com/help/account/membership/programs-overview
https://developer.apple.com/help/account/basics/about-your-developer-account
https://developer.apple.com/library/archive/featuredarticles/iPhoneURLScheme_Reference/PhoneLinks/PhoneLinks.html

## Real screen capture

Source commit `0db2c61` passed native tests/build and captured all five current
screens on fresh iPhone 11 and iPhone 16 simulators running iOS 18.5:
https://github.com/entrixy/ios/actions/runs/41282455115

The screens are Управление, Настройки, Гости, Журнал and Добавить ключ. These are
real empty-state captures of the first implementation, not a finished full port.
The ten PNG files were visually reviewed and copied at the user's request into
the existing website upload gallery. No user keys or mock objects were inserted.

The initial unsigned simulator build could not access Keychain. Xcode now embeds
simulator entitlements and uses local ad-hoc signing. This requires no Apple
Developer membership and does not replace physical-device distribution signing.
The capture script verifies a DEBUG/simulator-only readiness diagnostic before
saving an image, without recording credentials or the installation identity.


## Live guest preview and interface refinement (2026-11-01)

Commit `de522c4` passed native tests/build and captured six distinct screens on
both iPhone 11 and iPhone 16 simulators with an authorized real invitation:
four network objects and one Bluetooth object. Names are decrypted from owner
metadata; the transport still performs no opening commands. Object cards now
navigate to a read-only detail screen, and settings show the actual object count.

The invitation and stable test installation identity stay outside Git. A temporary
bootstrap verified GitHub's official workload identity with an exact repository,
workflow, immutable subject, source SHA and expiry. It supplied state only to a
fresh simulator's private data container; state is persisted in Keychain before
binding and never included in the app archive or build reports. The temporary
endpoint was disabled immediately after delivery. Release/device builds contain
no bootstrap import code.

The gallery now uses one device's set to avoid repeating every screen for two
models. Both models remain covered by private screenshot review. The first live
review also caught iOS replacing the empty-form button's semantic accent with gray;
`bd49e2c` uses an explicit primary color. Its repeat capture passed native tests/build and all 12 captures:
https://github.com/entrixy/ios/actions/runs/41285997605


Android visual resources are now imported: eight byte-identical object presets,
existing Entrixy horizontal/vertical logos as vector PDF assets, the Android launcher
artwork, matching outlined Material navigation icons, and Android Primary40 color.
`avatar_type` is read only from decrypted owner metadata or the encrypted BLE bundle.
Missing/unavailable custom file avatars use Android's preset-zero fallback. Owner-encrypted custom avatar transport is implemented in the next milestone below. `DesignSources/asset-provenance.json`
records original paths and hashes; original SVGs are retained. Material icons include
Apache 2.0 attribution and an in-app license screen. Commit `824efc6` passed all 16 native tests, the Xcode simulator build and all
12 real captures with the original artwork, reviewed on iPhone 11 and iPhone 16:
https://github.com/entrixy/ios/actions/runs/41288811744

Six distinct iPhone 16 screens are published in the existing upload gallery; the
previous empty/interim sets were archived privately. iPhone 11 images remain in the
private QA capture set. Real object metadata selected the correct gate, barrier,
house and lock artwork. The initial asset run compiled successfully but its capture
hung while terminating an app that had never launched; the capture script now skips
that unnecessary command on fresh simulators. No opening commands were sent.


## Larger guest-workflow milestone — verified on 2026-11-01

- Foreground live WSS events, bounded buffering, heartbeat, reconnect backoff and
  immediate cancellation when backgrounded or removing a key. Revocation and pause
  update the current UI; malformed updates cannot clear the last valid object list.
- Search, pull-to-refresh, key details and confirmed local key deletion. Installation
  identity is preserved; deleting a local entry does not revoke it on the owner's side.
- Dated local journal survives relaunches in the protected Keychain state, with
  backwards-compatible decoding for installations created before journal support.
- Encrypted custom avatar requests match Android's avatar_request/avatar_data
  protocol. Only authenticated owner ciphertext is accepted; current/previous object
  keys are supported. Disk cache stores ciphertext, memory stores validated images.
- Import by explicit paste, camera QR, photo QR and entrixy://key app links. Opening
  or scanning a link only fills the import form; adding remains an explicit action.
  Arbitrary HTTPS hosts are supported by QR/paste; universal-link association is not
  configured. Company/delegation/sticker QR formats are not yet implemented.

Source `28e6a52` passed all 21 core tests with Apple CryptoKit, the Xcode app
build, four hosted native tests, and 14 actual captures on iPhone 11 and iPhone 16:
https://github.com/entrixy/ios/actions/runs/41293692538

The native tests verify legacy Keychain decoding, corrupt-state preservation,
local deletion/journal persistence without identity replacement, and valid/blank
photo QR recognition. Independent PNG fixtures avoid coupling the test oracle to
Core Image's runtime filter registry. Photo decoding also supports a fallback to
an older supported Vision request revision when the current implementation fails.

All fourteen capture manifests report five real objects and one authenticated live
connection; journal counts across repeated launches were 1–4. Both model layouts
were visually reviewed. Seven distinct main screens are published in the existing
upload gallery; the preceding six images are archived privately. The extra screen
is received-key details. No invitation or installation identity is in tracked source,
build artifacts or public images. The temporary preview endpoint is disabled.

Camera scanning still requires physical-device verification. No actuation or BLE
commands were sent; full owner/action/automation/delegation flows remain pending.


## Corrected Android semantics and iOS presentation — verified

Android ActionCard does not navigate to a generic object-inspection page. That
invented page and its disclosure navigation have been removed. The current read-only
stage displays objects directly; it does not simulate unimplemented opening actions.

Android Journal is action history: timestamp, initiator, target and actual result.
Connection/synchronization/key-removal diagnostics no longer enter this journal.
Legacy diagnostic-only rows are decoded safely and filtered without replacing the
installation identity. The action schema and delayed result update windows follow
Android Journal; share/copy/clear and an honest empty state follow the same behavior.
No fabricated action history is added to previews.

Design references and rationale are in `docs/ios-design-reference.md`: Apple Home,
Wallet and Phone, with Android remaining the source for product behavior/artwork.
Primary actions use Entrixy's navy, secondary actions are neutral full-width rows,
and key information uses readable neutral labels and stronger values. Disabled
primary buttons use neutral surfaces and readable text, not pale blue fills.

Source `d79a3a4` passed all 21 core tests, five hosted native tests, the Xcode app
build and 12 actual captures (six main screens on each iPhone 11/16 simulator):
https://github.com/entrixy/ios/actions/runs/41298587295

All capture manifests verify five real objects, an authenticated live connection
and zero manufactured journal entries. Both model layouts were visually reviewed.
Six final screenshots are published in the upload gallery, replacing the rejected
seven-screen set and the interim single-device design preview. The invented object
page is absent. Identity-preserving legacy diagnostic cleanup and action result
persistence are verified by the added native migration test.

The first corrected-style run passed all 26 tests and captured iPhone 16, but a
read-connection failure blocked the later iPhone 11 capture. Temporary read failures
now use the inline connection state and reconnect without a stale modal alert;
permanent access/policy/storage failures remain explicit. The full repeat run above
passed both models. The preview bootstrap endpoint is disabled.

## Manual guest commands — verified in simulator

Direct card actions now use the full Android press-v1 signature (invitation base
key), socket capability and 16-byte nonce/HMAC proof, and explicit open/close
intent. One outstanding call is allowed per guest connection; uncertain writes
are not retried. Disconnect, background, key removal and policy changes invalidate
pending authorization. An attempt is persisted before sending; relaunch never
replays it. Controller text enters the action journal verbatim and is never
fabricated from a successful socket write.

Owner confirmation, a local 4–8 digit Entrixy code (PBKDF2-SHA256/60,000, persistent
escalating lockout), and biometric-only Keychain access bound to the current
biometric enrollment are implemented. Device passcode is not a biometric fallback.
Unsupported combined access conditions, network/time restrictions and missing
socket credentials block commands with an explanation. Manual override in Android
ANY mode is preserved. BLE commands and automatic conditions remain unimplemented.

Local tests use a recording controller and public test keys, including independent
HMAC and PBKDF2 vectors, challenge replay/expiry, offline refusal, authentication,
journal persistence and background cancellation. No supplied real invitation is
used to actuate hardware. Physical operation and real Face ID remain unverified.

Final verification for manual commands is source `2a91220` / Actions run
`41304975510`: 26 core + 9 hosted native tests passed. Native integration tests
use an isolated Keychain service and a recording controller. They verify durable
attempts before sends, single-use challenges, offline refusal, local authentication,
PIN lockout persistence, journal recovery, clearing history during an active
command without losing its live result or resurrecting a row, and background
cancellation without replay. One response window (up to 30 seconds) is allowed per
guest connection; a new transport is required before another call. This avoids
attributing legacy responses without an object ID to a later action.

All twelve read-only captures contain five real objects, an authenticated live
connection and zero journal entries. Six reviewed iPhone 16 images with suffix
`2a91220.png` replace the preceding set in the existing upload gallery; iPhone 11
captures remain private QA. Opening/closing actual hardware and real Face ID still
need physical-device verification. No TestFlight or device signing was configured.

## New action-flow screenshots

`--capture-actions <scenario>` is available only in DEBUG simulator builds. It
starts a separate app root and isolated Keychain service with public fixture keys
and a reserved `.invalid` server. It never loads the normal installation state,
imports a private bootstrap, binds a guest, or opens a WebSocket. A software
controller records the actual signed call and verifies the nonce/HMAC response
before returning its explicitly labelled test result through the normal model.
The journal is produced by this executed test flow, not populated with invented
entries. Every captured screen carries a visible test-stand banner.

CI `scripts/capture_simulator.py --action-flows` captures ten new states on each
phone: open/close confirmation, code setup/entry/rejection, authentication choices,
request sent, controller result, the resulting journal entry, and offline refusal.
It verifies frame/journal counts per scenario; real-key read-only snapshots remain
available via the script's default mode with its zero-journal assertion unchanged.
The code form now scrolls when the keyboard reduces the available height.
