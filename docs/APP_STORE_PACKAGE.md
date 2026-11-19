# Prepared release material

Source includes the app/icon/seven permission localizations, app and widget
privacy API manifests, iPhone/App Group/Wi-Fi/associated-domain entitlements and
the unsigned physical iPhone archive verifier. Signing, provisioning, an actual
device and App Store submission remain pending. Current IDs are provisional
com.entrixy.ios / com.entrixy.ios.widget / group.com.entrixy.ios; the previously
asked Team ID/Bundle ID question is still unanswered.

## Links

LiveAppRoot receives browsing activities through the same pendingURL path as
custom URLs. A locked app retains the pending link until its ordinary unlock;
link receipt does not authorize or execute an opening. Only the supported key,
delegation, company and claim routes are associated; the website's other pages
remain browser pages. Custom access-server domains are not silently claimed.

Generate a local file with confirmed provisioning identifiers:

```sh
python3 scripts/prepare_site_association.py \
  --application-identifier-prefix ACTUAL_PREFIX \
  --bundle-id ACTUAL_BUNDLE_ID
```

The command rejects placeholders/invalid identifiers and preserves an existing
output directory. It produces .local-checks/AppStore/association files, never
writes the live document root or assumes the site/CDN/device association works.
No Team ID/prefix or signing credential is invented. Publish the resulting JSON
at the exact .well-known path only after confirmed identifiers match the signed
app/profile, then verify HTTPS/no redirects, Apple CDN and device routing.

Primary source checked19November2026:
[Apple associated domains](https://developer.apple.com/documentation/xcode/supporting-associated-domains).

## Screenshots

Use original native review PNGs and their exact source/hash report. Preserve the
single light iPhone16 frame per state. The existing review resolution1179×2556
appears in Apple's current medium Dynamic Island table; the current required
device section names that class. Do not invent a requirement to duplicate every
screen on another device or resize/retouch screenshots. Verify the accepted
asset specification again in the actual App Store Connect account at upload.

Primary source checked19November2026:
[Apple screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications).

Only choose Store images after all45 checkpoints from the final source are
complete and visually reviewed. A partial/failed review and DEBUG fixture
isolation are recorded separately; screenshots cannot establish hardware readiness.

## Data inventory that must reach the final submission

- Protected access material and encrypted server bundles; account email only
  when the user links an account. Object/camera/webhook secrets have scoped paths.
- On-device location/Wi-Fi/Bluetooth conditions, optional camera/Photos access,
  Face ID and independent motion for configured geo warnings. No contacts read.
- Explicit-consent MetricKit crashes; manual technical reports only on request.
- Trusted promotion catalogue: per-install UUID, version/language, coarse usage
  tags/installation age and counted views; go.php processes clicks. Access-server
  credentials, names, SSIDs and coordinates are excluded from those requests.
- Local installation/cache/diagnostic state is excluded from user backups.
  Network-service IP/log handling and retention still require the actual server
  inventory; a No Data Collected declaration has not been made.

The current public privacy page describes Android and does not yet describe the
new iOS diagnostic/catalogue processing. Its URL must not be presented as an
approved final iOS privacy policy. Prepare the factual iOS update from this data
inventory and the server's retention settings before submission. App Store privacy
answers, export compliance, age rating, reviewer access and real-device evidence
remain explicit release gates, not inferred successes from an unsigned archive.
