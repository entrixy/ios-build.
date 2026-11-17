import XCTest
@testable import EntrixyCore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

final class CompanyTests: XCTestCase {
    private let signing = Curve25519.Signing.PrivateKey()
    private func profile(server: String = "entrixy.com") throws -> KnownCompany {
        try KnownCompany(server:server,json:["org_id":11,"name":"Доставка","domain":"company.example","verified":true,"logo":"/img/org/logo.png","pubkey":signing.publicKey.rawRepresentation.base64EncodedString()],pendingCode:"CODE_11")
    }
    private func owner() throws -> OwnerAccount {
        var owner = try OwnerAccount(server:"entrixy.com")
        var object = try OwnerObject(masterKey:owner.masterKey,label:"Ворота",kind:"call",phone:"+79990001122",url:"",secret:"",claimCode:"")
        object.numberID = 7; object.pending = nil; object.available = true
        owner.objects = [object]; return owner
    }
    private func press(body: String, now: Int64 = 1000) throws -> [String:Any] {
        let nonce = String(repeating:"a",count:32), domain = "company.example"
        let material = Data("\(domain).\(now).\(nonce).\(GuestCrypto.hash(Data(body.utf8)))".utf8)
        return ["org":["domain":domain,"ts":now,"nonce":nonce,"body":body,"sig":try signing.signature(for:material).base64EncodedString()]]
    }
    func testCompanyInviteServerScopingAndTrustedBranding() throws {
        XCTAssertEqual(try CompanyInvite.parse("entrixy://company?code=ABC_123&h=owner.example").server,"owner.example")
        XCTAssertEqual(try CompanyInvite.parse("https://entrixy.com/c/ABC_123").code,"ABC_123")
        XCTAssertEqual(try CompanyInvite.parse("https://owner.example/o/legacy").server,"owner.example")
        for raw in ["http://entrixy.com/c/a","entrixy://company?code=a&code=b","https://user@entrixy.com/c/a","https://entrixy.com/c/a/b","entrixy://company?code=..","https://entrixy.com/c/a#secret"] { XCTAssertThrowsError(try CompanyInvite.parse(raw),raw) }
        XCTAssertTrue(try profile().proven); XCTAssertFalse(try profile(server:"owner.example").proven)
        XCTAssertNotEqual(try profile().id,try profile(server:"owner.example").id)
    }
    func testCompanyGrantIsCallOnlyNonDelegatingWithExplicitPublicObjectLabels() throws {
        var owner = try owner()
        let key = try OwnerIssuedKey.forCompany(owner:owner,profile:profile(),numberIDs:[7])
        let body = try JSONSerialization.jsonObject(with:key.request(masterKey:owner.masterKey)) as! [String:Any]
        XCTAssertEqual(body["org_id"] as? Int,11); XCTAssertEqual(body["org_code"] as? String,"CODE_11")
        XCTAssertEqual((body["org_labels"] as? [String:String])?["7"],"Ворота")
        XCTAssertEqual(key.grantedAccess?["7"],try KeyObjectAccess(depth:0,pool:1))
        XCTAssertFalse(String(decoding:try key.request(masterKey:owner.masterKey),as:UTF8.self).contains(try key.secrets(masterKey:owner.masterKey).userKey))
        owner.issuedKeys = [key]; XCTAssertThrowsError(try OwnerIssuedKey.forCompany(owner:owner,profile:profile(),numberIDs:[7]))
        var webhook = try OwnerObject(masterKey:owner.masterKey,label:"Webhook",kind:"webhook",phone:"",url:"https://hook.example/",secret:"secret",claimCode:"")
        webhook.numberID = 8; webhook.pending = nil; webhook.available = true; owner.objects?.append(webhook)
        XCTAssertThrowsError(try OwnerIssuedKey.forCompany(owner:owner,profile:profile(),numberIDs:[8]))
        var confirmed = key; confirmed.keyID = 17; confirmed.state = .active; confirmed.pending = nil; owner.issuedKeys = [confirmed]
        XCTAssertThrowsError(try confirmed.link(server:owner.server,masterKey:owner.masterKey))
        XCTAssertThrowsError(try confirmed.cloned(owner:owner,label:"Копия"))
        XCTAssertThrowsError(try confirmed.edit(owner:owner,label:"Доставка",numberIDs:[8],welcome:""))
    }
    func testMergedCreateNeverAdoptsExistingIdentity() throws {
        let owner = try owner()
        var key = try OwnerIssuedKey.forCompany(owner:owner,profile:profile(),numberIDs:[7]); key.sent = true
        let original = key
        XCTAssertThrowsError(try key.acceptCreationReply(["id":99,"merged":1,"org_id":11]))
        XCTAssertEqual(key,original)
        XCTAssertThrowsError(try key.acceptCreationReply(["id":99,"org_id":12]))
        try key.acceptCreationReply(["id":17,"org_id":11]); XCTAssertEqual(key.keyID,17)
    }
    func testExactSignedBodyBindsCompanyKeyActorObjectAndWindow() throws {
        let raw = #"{ "actor":"Иван", "number_id":7, "key_ref":17 }"#
        let signed = try press(body:raw)
        let valid = try CompanyPress.verify(signed,publicKey:signing.publicKey.rawRepresentation,keyID:17,numberID:7,numberIDs:[7,8],expectedAction:"",now:1600)
        XCTAssertEqual(valid.actor,"Иван")
        for (id,number,action,now) in [(18,7,"",1000),(17,8,"",1000),(17,7,"open",1000),(17,7,"",1601)] {
            XCTAssertThrowsError(try CompanyPress.verify(signed,publicKey:signing.publicKey.rawRepresentation,keyID:id,numberID:number,numberIDs:[7,8],expectedAction:action,now:Int64(now)))
        }
        var tampered = signed, org = signed["org"] as! [String:Any]; org["body"] = raw.replacingOccurrences(of:"Иван",with:"Пётр"); tampered["org"] = org
        XCTAssertThrowsError(try CompanyPress.verify(tampered,publicKey:signing.publicKey.rawRepresentation,keyID:17,numberID:7,numberIDs:[7],expectedAction:"",now:1000))
        for body in [#"{"key_ref":17,"number_id":7}"#,#"{"key_ref":17,"number_id":7,"actor":" "}"#] {
            XCTAssertThrowsError(try CompanyPress.verify(press(body:body),publicKey:signing.publicKey.rawRepresentation,keyID:17,numberID:7,numberIDs:[7],expectedAction:"",now:1000))
        }
    }
    func testOmittedObjectAllowedOnlyForSingletonAndLocalPinWins() throws {
        let signed = try press(body:#"{"key_ref":17,"actor":"Курьер"}"#)
        XCTAssertNoThrow(try CompanyPress.verify(signed,publicKey:signing.publicKey.rawRepresentation,keyID:17,numberID:7,numberIDs:[7],expectedAction:"",now:1000))
        XCTAssertThrowsError(try CompanyPress.verify(signed,publicKey:signing.publicKey.rawRepresentation,keyID:17,numberID:7,numberIDs:[7,8],expectedAction:"",now:1000))
        var owner = try owner(), key = try OwnerIssuedKey.forCompany(owner:owner,profile:profile(),numberIDs:[7])
        key.keyID = 17; key.state = .active; key.pending = nil; owner.issuedKeys = [key]
        let authorized = try XCTUnwrap(owner.authorizedGuest(keyID:17,numberID:7))
        XCTAssertEqual(try authorized.verifyPress(signed,server:owner.server,numberID:7,expectedAction:"",now:1000).actor,"Курьер")
        var withoutPin = key; withoutPin.company?.publicKey = nil; owner.issuedKeys = [withoutPin]
        XCTAssertNil(try owner.authorizedGuest(keyID:17,numberID:7))
        owner.issuedKeys = [key]; owner.issuedKeys![0].state = .paused
        XCTAssertNil(try owner.authorizedGuest(keyID:17,numberID:7))
        let stranger = Curve25519.Signing.PrivateKey()
        XCTAssertThrowsError(try CompanyPress.verify(signed,publicKey:stranger.publicKey.rawRepresentation,keyID:17,numberID:7,numberIDs:[7],expectedAction:"",now:1000))
    }
}
