import XCTest
@testable import EntrixyCore

final class EventSoundBackupTests: XCTestCase {
    func testOriginalBytesAndPreferencesRoundTripWithoutDeviceSpecificPaths() throws {
        let sample = Data([1,2,3,4])
        let source = try EventSoundBackup(volume:0.35,muted:["message","incall"],samples:["tap":sample])
        let result = try JSONDecoder().decode(EventSoundBackup.self,from:JSONEncoder().encode(source)); try result.validate()
        XCTAssertEqual(result,source); XCTAssertEqual(result.samples["tap"],sample)
        XCTAssertEqual(EventSoundBackup.events.count,9)
    }
    func testInvalidVolumeEventPathEmptySampleOrAmbiguousMissingSampleIsRejected() throws {
        XCTAssertThrowsError(try EventSoundBackup(volume:.nan,muted:[],samples:[:]))
        XCTAssertThrowsError(try EventSoundBackup(volume:2,muted:[],samples:[:]))
        XCTAssertThrowsError(try EventSoundBackup(volume:0.1,muted:["unknown"],samples:[:]))
        XCTAssertThrowsError(try EventSoundBackup(volume:0.1,muted:[],samples:["../tap":Data([1])]))
        XCTAssertThrowsError(try EventSoundBackup(volume:0.1,muted:[],samples:["tap":Data()]))
        XCTAssertThrowsError(try EventSoundBackup(volume:0.1,muted:[],samples:["tap":Data([1])],unavailableSamples:["tap"]))
    }
    func testAndroidVolumeAndMuteTransferButContentURIsAreReportedAsMissingAudio() throws {
        let entries: [String:Any] = ["app_volume":["t":"f","v":0.6],"mute_tap":["t":"b","v":true],"mute_success":["t":"b","v":false],"sound_geo":["t":"s","v":"content://old-phone/audio/7"]]
        let document = try AndroidBackupDocument(JSONSerialization.data(withJSONObject:["app":"entrixy","ver":1,"created":1_800_000_000,"device":"Public fixture","count":entries.count,"entries":entries]))
        let result = try document.eventSoundBackup()
        XCTAssertEqual(result.volume,0.6,accuracy:0.00001); XCTAssertEqual(result.muted,["tap"])
        XCTAssertTrue(result.samples.isEmpty); XCTAssertEqual(result.unavailableSamples,["geo"])
    }
}
