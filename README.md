# Entrixy iOS build

Native iOS application source and automated build checks. Work in progress; this snapshot has not yet passed an Apple build or device validation.

Generate the Xcode project with `xcodegen generate`. Run core tests with `swift test`. The Actions workflow builds Debug and Release simulator applications, runs native tests, and captures isolated software test scenarios. Simulator builds cannot be installed on a physical iPhone or submitted to the App Store.

Capture fixtures use synthetic data and do not prove hardware compatibility. No new distribution license is granted; bundled third-party notices remain in ThirdParty and App/Resources.
