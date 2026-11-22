import XCTest
@testable import EntrixyCore

final class DelegationWelcomeTests: XCTestCase {
    func testFragmentAuthenticatedWelcomeKeepsSenderAndTextWithPendingAndReceipt() throws {
        let link = try DelegationLink(server:"welcome.invalid",group:String(repeating:"G",count:22),secret:Data(repeating:31,count:32))
        let cipher = try GuestCrypto.encrypt(key:link.secret,plaintext:JSONSerialization.data(withJSONObject:["from":"Анна","text":"Вход со двора."]))
        let info = try JSONSerialization.data(withJSONObject:["grp":link.group,"state":"new","welcome_cipher":cipher,"parts":[["code":String(repeating:"C",count:22),"state":"new"]]])
        var pending = try DelegationRedemption(link:link,info:info)
        XCTAssertEqual(pending.welcomeCipher,cipher)
        let welcome = try DelegationWelcome.open(cipher,secret:link.secret)
        XCTAssertEqual(welcome.from,"Анна"); XCTAssertEqual(welcome.text,"Вход со двора.")
        pending.sent = true; pending.completedCodes = pending.parts.map(\.code)
        let receipt = try ReceivedDelegation(pending:pending)
        XCTAssertEqual(try JSONDecoder().decode(ReceivedDelegation.self,from:JSONEncoder().encode(receipt)).welcomeCipher,cipher)
        XCTAssertThrowsError(try DelegationWelcome.open(cipher,secret:Data(repeating:32,count:32)))
    }
    func testUnauthenticatedOptionalWelcomeCannotReplaceSenderButDoesNotRejectValidKeyParts() throws {
        let link = try DelegationLink(server:"welcome.invalid",group:String(repeating:"G",count:22),secret:Data(repeating:31,count:32))
        let cipher = try GuestCrypto.encrypt(key:Data(repeating:32,count:32),plaintext:Data(#"{"from":"forged","text":"not authenticated"}"#.utf8))
        let info = try JSONSerialization.data(withJSONObject:["grp":link.group,"state":"new","welcome_cipher":cipher,"parts":[["code":String(repeating:"C",count:22),"state":"new"]]])
        let pending = try DelegationRedemption(link:link,info:info)
        XCTAssertNil(pending.welcomeCipher); XCTAssertEqual(pending.parts.count,1)
    }
    func testImportedGroupSkipsRedeemedPartsAndKeepsRecipientWhenNewPartArrives() throws {
        let link = try DelegationLink(server:"welcome.invalid",group:String(repeating:"G",count:22),secret:Data(repeating:31,count:32))
        let recipient = BundleKeySeal.makeRecipient()
        let originalID = link.server + ":" + GuestCrypto.hash(Data(repeating:11,count:32))
        let oldCode = String(repeating:"B",count:22), newCode = String(repeating:"C",count:22)
        let info = try JSONSerialization.data(withJSONObject:["grp":link.group,"state":"new","parts":[["code":oldCode,"state":"redeemed"],["code":newCode,"state":"new"]]])
        let baseline = try DelegationRedemption.redeemedCodes(info:info,group:link.group)
        var pending = try DelegationRedemption(link:link,info:info,recipient:recipient,excludingCodes:Set(baseline),importedGuestIDs:[originalID],importedBaselineCodes:baseline)
        XCTAssertEqual(pending.parts.map(\.code),[newCode]); XCTAssertEqual(baseline,[oldCode])
        pending.sent = true; pending.completedCodes = [newCode]
        var receipt = try ReceivedDelegation(importing:link,recipient:recipient,guestIDs:[originalID])
        try receipt.merge(ReceivedDelegation(pending:pending))
        XCTAssertEqual(receipt.recipient.privateKey,recipient.privateKey)
        XCTAssertTrue(receipt.guestIDs.contains(originalID)); XCTAssertEqual(receipt.guestIDs.count,2)
        XCTAssertEqual(receipt.importedBaselineCodes,[oldCode]); XCTAssertEqual(receipt.welcomeQueued,true)
        let restored = try JSONDecoder().decode(ReceivedDelegation.self,from:JSONEncoder().encode(receipt))
        XCTAssertEqual(restored.guestIDs,receipt.guestIDs)
        XCTAssertThrowsError(try ReceivedDelegation(importing:link,recipient:recipient,guestIDs:["another.invalid:" + String(repeating:"a",count:64)]))
    }
}
