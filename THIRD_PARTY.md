# Third-party components

The iOS/macOS targets use system Foundation, CryptoKit, Security and SwiftUI.
No external runtime package is added to the Apple build by Package.swift.

Linux protocol tests use Apple's swift-crypto 3.15.1 (Apache-2.0), which includes
its separately licensed BoringSSL-derived sources. The checkout retains those
source headers. SwiftPM also resolves swift-asn1 1.6.0 (Apache-2.0). Versions and
revisions are recorded in Package.resolved; upstream root LICENSE/NOTICE files
are preserved under ThirdParty. The .build source checkouts and Linux test
binaries are local development artifacts, not distributed iOS assets.

XcodeGen is a build tool used by CI, not linked into the app. The workflow uses
GitHub's official checkout/upload-artifact actions pinned to commit SHAs.

The unchanged client-v1.json is the public Entrixy protocol test fixture. Its
credentials are deterministic test values, not production access credentials.
