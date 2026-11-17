import XCTest
import AVFoundation
import EntrixyCore
@testable import Entrixy

@MainActor final class AppSoundTests: XCTestCase {
    private func fixture() -> (AppSoundCenter,UserDefaults,URL,String) {
        let suite = "com.entrixy.tests.sounds."+UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        return (AppSoundCenter(defaults:defaults,directory:directory.appendingPathComponent("custom"),notificationDirectory:directory.appendingPathComponent("notification")),defaults,directory,suite)
    }
    func testAudioBackupRestoresExactSamplesAndPreferencesAcrossRelaunch() throws {
        let (sounds,defaults,directory,suite) = fixture()
        defer { defaults.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:directory) }
        let original = try Data(contentsOf:XCTUnwrap(sounds.defaultURL(.success)))
        let material = try EventSoundBackup(volume:0.35,muted:["message","incall"],samples:["success":original])
        let stage = try sounds.prepareRestore(material)
        XCTAssertEqual(sounds.volume,0.1,accuracy:0.00001); XCTAssertTrue(sounds.custom.isEmpty)
        var committed = false
        try sounds.commitRestore(stage,commitAccess:{ committed = true }); sounds.discardUnusedRestore(stage)
        XCTAssertTrue(committed); XCTAssertEqual(try sounds.backupMaterial(),material)
        let reloaded = AppSoundCenter(defaults:defaults,directory:directory.appendingPathComponent("custom"),notificationDirectory:directory.appendingPathComponent("notification"))
        XCTAssertEqual(try reloaded.backupMaterial(),material)
        XCTAssertNotNil(reloaded.notificationSound(.success)); XCTAssertNil(reloaded.notificationSound(.message))
    }
    func testCorruptSampleAndFailedAccessCommitPreservePreviouslySelectedSound() throws {
        let (sounds,defaults,directory,suite) = fixture()
        defer { defaults.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:directory) }
        sounds.setVolume(0.7); sounds.setEnabled(.tap,false)
        let before = try sounds.backupMaterial()
        let corrupt = try EventSoundBackup(volume:0.2,muted:[],samples:["tap":Data("not audio".utf8)])
        XCTAssertThrowsError(try sounds.prepareRestore(corrupt)); XCTAssertEqual(try sounds.backupMaterial(),before)
        let original = try Data(contentsOf:XCTUnwrap(sounds.defaultURL(.success)))
        let material = try EventSoundBackup(volume:0.25,muted:[],samples:["success":original])
        let stage = try sounds.prepareRestore(material)
        XCTAssertThrowsError(try sounds.commitRestore(stage,commitAccess:{ throw CocoaError(.fileWriteUnknown) }))
        sounds.discardUnusedRestore(stage)
        XCTAssertEqual(try sounds.backupMaterial(),before)
        let reloaded = AppSoundCenter(defaults:defaults,directory:directory.appendingPathComponent("custom"),notificationDirectory:directory.appendingPathComponent("notification"))
        XCTAssertEqual(try reloaded.backupMaterial(),before)
    }
    func testAllNineOriginalEventResourcesAreBundledAndDecodable() throws {
        let (sounds,defaults,directory,suite) = fixture()
        defer { defaults.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:directory) }
        XCTAssertEqual(AppSoundEvent.allCases.count,9)
        XCTAssertEqual(sounds.volume,0.1,accuracy:0.00001)
        for event in AppSoundEvent.allCases {
            let url = try XCTUnwrap(sounds.defaultURL(event),event.rawValue)
            let player = try AVAudioPlayer(contentsOf:url)
            XCTAssertTrue(player.duration.isFinite); XCTAssertGreaterThan(player.duration,0)
        }
    }
    func testCustomImportAndSettingsSurviveRelaunchWithoutReplacingFileOnDecodeFailure() throws {
        let (sounds,defaults,directory,suite) = fixture()
        defer { defaults.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:directory) }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let original = try Data(contentsOf:XCTUnwrap(sounds.defaultURL(.success)))
        let chosen = directory.appendingPathComponent("chosen.mp3"); try original.write(to:chosen)
        try sounds.importSound(chosen,event:.success)
        sounds.setVolume(0.45); sounds.setEnabled(.success,false)
        let reloaded = AppSoundCenter(defaults:defaults,directory:directory.appendingPathComponent("custom"))
        XCTAssertEqual(reloaded.volume,0.45,accuracy:0.00001); XCTAssertTrue(reloaded.muted.contains(.success)); XCTAssertTrue(reloaded.custom.contains(.success))
        try Data("invalid audio".utf8).write(to:chosen)
        XCTAssertThrowsError(try reloaded.importSound(chosen,event:.success))
        XCTAssertEqual(try Data(contentsOf:directory.appendingPathComponent("custom/success.audio")),original)
        reloaded.reset(.success)
        XCTAssertFalse(reloaded.custom.contains(.success)); XCTAssertFalse(FileManager.default.fileExists(atPath:directory.appendingPathComponent("custom/success.audio").path))
    }
    func testNotificationSoundIsBoundedLocalAudioAndHonorsMuteAndMasterVolume() throws {
        let (sounds,defaults,directory,suite) = fixture()
        defer { defaults.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:directory) }
        sounds.setEnabled(.incall,false); XCTAssertNil(sounds.notificationSound(.incall))
        sounds.setEnabled(.incall,true); sounds.setVolume(0); XCTAssertNil(sounds.notificationSound(.incall))
        sounds.setVolume(0.1); XCTAssertNotNil(sounds.notificationSound(.incall))
        let files = try FileManager.default.contentsOfDirectory(at:directory.appendingPathComponent("notification"),includingPropertiesForKeys:nil)
        XCTAssertEqual(files.count,1)
        let decoded = try AVAudioPlayer(contentsOf:XCTUnwrap(files.first))
        XCTAssertGreaterThan(decoded.duration,0); XCTAssertLessThan(decoded.duration,30)
        XCTAssertTrue(files[0].lastPathComponent.hasPrefix("entrixy-incall-"))
    }
}
