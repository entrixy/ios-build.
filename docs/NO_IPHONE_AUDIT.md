# Full software scope — 22 November 2026

The task remains the complete Android10.90 port, not approval of a limited package.
Android reference: `56155352b0e9f36ef3685aa071a6aafdb2ef6622`.
The fifty functional rows are in ANDROID_IOS_PARITY.md. Source presence, actual
Apple runtime results, operational activation and hardware acceptance are distinct.
This document records the source audit; it does not declare the app ready to submit.

## Source corrections

- `/ws` is served by the Go executable `private/bin/entrixy-ws`, listening on8095,
  source `private/ws-go`. The PHP `w/server.php` is legacy. Active Go handlers/calls
  implement `client=app` classification and preserve signed guest `press` frames.
  iOS already sends app classification with its signed hello. Do not add an
  invented App Attest/HMAC protocol or embed a server secret to fix legacy code.
  App-policy rejection retains keys and stops repeating the same refused hello;
  the seven-language message now describes that fact without claiming missing
  attestation support.
- Android `App.checkVersionAsync` skips APK updates when `build_store` is nonempty.
  Store-distributed iOS follows its store; an APK updater/force-update screen is
  not an omitted feature. No such screen was added.
- Android `store/ObjectMove.kt` implements BLE moves; iOS OwnerBLEMove implements
  that scope. A general cross-server transfer of every object type is not the
  Android contract and was not invented.

## Confirmed software gaps addressed in the current source

- Camera: Android actually links Media3 DASH/RTSP. iOS previously rejected its
  entire otherVideo branch. It now uses official VideoLAN VLCKit for RTSP, DASH,
  WebM and MKV, retaining existing JPEG/MJPEG/native HLS/MP4. The decoder receives
  only loopback capabilities. The app owns pinned-origin HTTP authorization,
  DASH manifest/template rewriting, RTSP framing, SDP/control URI rewriting,
  Basic/Digest authorization and TCP-interleaved RTP. Foreign origins, unsafe
  XML, network clock/steering side paths and unexpected RTSP methods fail closed.
  This is no claim of RTMP parity: Android does not link the Media3 RTMP extension.
- Actual decoder regressions use tiny synthetic WebM and DASH media, requiring
  video output rather than a constructed player or HTTP200. RTSP tests use an
  actual loopback server and verify Digest/rewritten SDP/foreign-origin denial.
  The original user's artwork and screenshots are unchanged.
- The SDK is pinned to official source7f98c70f9f0c11fbdf828220890bd6280361ae99,
  binary20261109-1916, SHA256
  `1fec7232f88e706f44d9a015133e08d742166eb2666cb44915c9f570bf339463`.
  Actual physical-iOS arm64 dynamic Mach-O was inspected locally. Notices/source
  access are packaged and shown under Licenses; the device archive checks the
  dynamic framework, its physical platform, notice and exclusion from the widget.
  No SDK binary or generated build archive is committed.
- Message-only Entrixy guests now require alert permission even with no automation
  or owner-call rules. APNs token registration is separate from alert permission.
  Existing server message/share-message alerts are retained; share-part remains a
  silent hint. Provider credentials, signing and actual delivery are external gates.
- Server-data deletion initiation is separate from local RESET. System settings
  offer device scope or a whole linked account, exact DELETE confirmation and
  fresh account authentication. A protected receipt precedes network access;
  lost responses/relaunch keep its id, passwords/JWTs are never persisted, pending
  is not displayed as completed, and status works after credentials are removed.
  The backend/operator runbook is `install/DATA_DELETION.md` in the website repo.
  It is intentionally disabled until retention, a responsible processor and the
  deadline are approved. The code does not automatically erase accounts or falsely
  promise an unmonitored service. No real account/request has been created/deleted.

## Remaining acceptance and activation

The new source has not yet passed its complete Apple SDK/runtime/gallery batch.
Expected:321core,223hosted,34UI,66 native PNGs plus4 original Store JPEG candidates;
counts are coverage targets, not product-completion percentages. See CURRENT_STATUS
for the actual final-source result. Do not publish partial or older-source images.

No physical device is required to prepare signing inputs, AASA, privacy inventory,
metadata, queue schemas or provider code; these are prepared. Actual Team ID,
App ID prefix/bundle/group, APNs credentials/topic, deletion processing/retention
approval, final privacy/export/reviewer answers and Store account access cannot be
invented. Deletion/APNs activation and public associated-domain deployment remain
explicitly pending until those inputs match real service/provisioning.

iOS telephone handoff requires foreground user/system confirmation; Android
background auto-dial/hangup and persistent HostService are unavailable as equivalent
iOS APIs. The app reports actual owner availability rather than pretending a
suspended owner socket is online. No new owner background-push execution protocol
was invented. Physical BLE/camera/GPS/Wi-Fi/cellular/background, real Android exchange,
signed installation, TestFlight and final App Store review still need acceptance.

Primary implementation references:
[official VLCKit](https://github.com/videolan/vlckit),
[Apple account-deletion guidance](https://developer.apple.com/help/app-review/guideline-reference/5-1-1-account-deletion).
