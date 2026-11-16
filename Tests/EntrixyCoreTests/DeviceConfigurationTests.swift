import XCTest
@testable import EntrixyCore

final class DeviceConfigurationTests: XCTestCase {
    private let master = Data(repeating: 73,count: 32)
    func testRegistrationCredentialsSurviveDurableTransitionWithoutEnteringObjectCipher() throws {
        var object = try OwnerObject(masterKey: master,label:"Ворота",kind:"device",registerDevice:true)
        XCTAssertEqual(object.pending,.deviceRegister)
        XCTAssertEqual(try JSONSerialization.jsonObject(with:object.request()) as? [String:String], [:])
        let key = String(repeating:"a",count:32), secret = String(repeating:"b",count:32)
        XCTAssertThrowsError(try object.acceptDeviceRegistration(id:9,key:key,secret:secret,masterKey:master))
        object.sent = true
        try object.acceptDeviceRegistration(id:9,key:key,secret:secret,masterKey:master)
        let restarted = try JSONDecoder().decode(OwnerObject.self,from:JSONEncoder().encode(object))
        XCTAssertEqual(restarted.pending,.create); XCTAssertFalse(restarted.sent)
        XCTAssertEqual(restarted.routing["device_id_ref"],"9")
        let credentials = try XCTUnwrap(restarted.deviceCredentials(masterKey:master))
        XCTAssertEqual(try credentials.code(server:"entrixy.com"),"ENTX-DEV:"+key+secret)
        XCTAssertEqual(try credentials.code(server:"other.invalid"),"ENTX-DEV:"+key+secret+"@other.invalid")
        XCTAssertFalse(String(decoding:try restarted.request(),as:UTF8.self).contains(secret))
        XCTAssertNil(try restarted.metadata(masterKey:master)["device_secret"])
        try restarted.validate(masterKey:master)
    }
    func testBindingSecretIsPersistableAndNeverRegeneratedWhenPanelIsReopened() throws {
        var object = try OwnerObject(masterKey:master,label:"Ворота",kind:"device",claimCode:"CLAIM")
        let code = try object.prepareSocketBinding(masterKey:master)
        XCTAssertTrue(code.hasPrefix("ENTX-BIND:")); XCTAssertEqual(code.count,74)
        object = try JSONDecoder().decode(OwnerObject.self,from:JSONEncoder().encode(object))
        XCTAssertEqual(try object.prepareSocketBinding(masterKey:master),code)
        XCTAssertFalse(String(decoding:try object.request(),as:UTF8.self).contains(String(code.dropFirst(10))))
    }
    func testMalformedRegistrationReplyDoesNotEraseTheOriginalPendingAttempt() throws {
        var object = try OwnerObject(masterKey:master,label:"Ворота",kind:"device",registerDevice:true)
        object.sent = true; let previous = object
        XCTAssertThrowsError(try object.acceptDeviceRegistration(id:9,key:"invalid",secret:"invalid",masterKey:master))
        XCTAssertEqual(object,previous); XCTAssertTrue(object.sent)
    }
}
