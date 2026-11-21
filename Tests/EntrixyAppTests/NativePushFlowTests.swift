import XCTest
import EntrixyCore
@testable import Entrixy

private final class PushAccessMemory: StateStorage {
    var state:SavedState?
    func load() throws -> SavedState? { state }
    func save(_ state:SavedState) throws { self.state = state }
}
private final class PushInboxMemory: NativePushInboxStorage {
    var state = NativePushInbox()
    var failRead = false, failSave = false
    var writes = 0
    func load() throws -> NativePushInbox { if failRead { throw URLError(.cannotDecodeContentData) }; return state }
    func save(_ inbox:NativePushInbox) throws {
        if failSave { throw URLError(.cannotWriteToFile) }; try inbox.validate(); state = inbox; writes += 1
    }
}
@MainActor private final class PushTransportRecorder: NativePushTransport,GuestMessageTransport {
    var registrations:[NativePushRegistration] = []
    var registeredIDs:[String] = []
    var polls = 0, delivered = 0, removed = 0
    var cipher:String?
    var beforeRegister:(() -> Void)?
    var beforePoll:(() -> Void)?
    func registerNativePush(_ registration:NativePushRegistration,invite:GuestInvite,fingerprint:String) async throws {
        registrations.append(registration); registeredIDs.append(invite.id); beforeRegister?()
    }
    func pendingNativeMessage(invite:GuestInvite,fingerprint:String) async throws -> String? { polls += 1; beforePoll?(); return cipher }
    func removeNativePush(_ registration:NativePushRegistration,invite:GuestInvite,fingerprint:String) async throws { removed += 1 }
    func acknowledgeMessage(invite:GuestInvite,fingerprint:String,kind:MessageAcknowledgement,hash:String) async throws {
        XCTAssertEqual(kind,.delivered); delivered += 1
    }
}

@MainActor final class NativePushFlowTests: XCTestCase {
    private func fixture(server:String = "entrixy.com",inbox:PushInboxMemory = PushInboxMemory(),access:PushAccessMemory? = nil) throws
        -> (AppModel,AppRemoteNotifications,PushInboxMemory,PushTransportRecorder,PushAccessMemory,GuestInvite) {
        let store = access ?? PushAccessMemory()
        let invite = try GuestInvite.parse("https://"+server+"/key#AAECAwQFBgcICQoLDA0ODxAREhMUFRYX"+String(repeating:"A",count:43))
        if store.state == nil { store.state = SavedState(identity:Data(repeating:19,count:32),guests:[SavedGuest(invite:invite)]) }
        let app = AppModel(storage:store),api = PushTransportRecorder()
        let service = AppRemoteNotifications(app:app,storage:inbox,api:api,environment:.sandbox,register:{},unregister:{})
        app.remoteNotifications = service; app.messages = MessageManager(app:app,acknowledgements:api)
        return (app,service,inbox,api,store,invite)
    }
    private func payload(_ invite:GuestInvite,type:String = "message") -> [AnyHashable:Any] {
        ["entrixy":["type":type,"server":invite.server,"hash":GuestCrypto.hash(Data(invite.userKey.utf8))]]
    }
    func testMessageOnlyGuestRequiresAlertPermissionWithoutLocationOrBluetooth() throws {
        let (app,_,_,_,_,_) = try fixture(); defer { app.suspend() }
        let needs = app.phoneRequirements()
        XCTAssertTrue(needs.notifications)
        XCTAssertFalse(needs.location)
        XCTAssertFalse(needs.bluetooth)
    }
    func testCustomServerWithoutNativePushDoesNotRequestAlertPermissionForAnEmptyKey() throws {
        let (app,_,_,_,_,_) = try fixture(server:"private.invalid"); defer { app.suspend() }
        XCTAssertFalse(app.phoneRequirements().notifications)
    }
    private func wait(_ condition:() -> Bool) async throws {
        for _ in 0..<100 { if condition() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        XCTFail("Push transaction did not finish")
    }
    func testBackgroundHintPersistsWithoutNetworkOrAcknowledgementAndUnlockFetchVerifiesBeforeDelivery() async throws {
        let (app,service,inbox,api,access,invite) = try fixture(); defer { app.suspend() }
        let identity = access.state?.identity
        app.suspend()
        XCTAssertTrue(service.receive(payload(invite)))
        XCTAssertEqual(inbox.state.events.count,1); XCTAssertEqual(api.polls,0); XCTAssertEqual(api.delivered,0)
        XCTAssertTrue(app.incomingMessages.isEmpty); XCTAssertTrue(app.journal.isEmpty)
        let (next,nextService,_,nextAPI,_,_) = try fixture(inbox:inbox,access:access); defer { next.suspend() }
        nextAPI.cipher = try GuestMessageCrypto.seal("Сообщение владельца",bundleKey:invite.bundleKey)
        nextAPI.beforePoll = { XCTAssertEqual(inbox.state.events.count,1) }
        nextService.activate()
        try await wait { nextAPI.delivered == 1 && inbox.state.events.isEmpty }
        XCTAssertEqual(next.incomingMessages.count,1); XCTAssertNil(next.incomingMessages[0].readAt)
        XCTAssertEqual(access.state?.identity,identity); XCTAssertTrue(next.journal.isEmpty)
    }
    func testUnreadableInboxAndFailedHintWriteCannotReplaceStateOrAcknowledgeAnything() async throws {
        let (app,service,inbox,api,_,invite) = try fixture(); defer { app.suspend() }
        inbox.failRead = true; XCTAssertFalse(service.receive(payload(invite)))
        service.receivedDeviceToken(Data(repeating:1,count:32))
        service.activate(); await Task.yield(); await Task.yield()
        XCTAssertTrue(api.registrations.isEmpty); XCTAssertEqual(api.polls,0); XCTAssertEqual(inbox.writes,0); XCTAssertTrue(app.incomingMessages.isEmpty)
        let (other,otherService,otherInbox,otherAPI,_,otherInvite) = try fixture(); defer { other.suspend() }
        otherInbox.failSave = true
        XCTAssertFalse(otherService.receive(payload(otherInvite)))
        XCTAssertTrue(otherInbox.state.events.isEmpty); XCTAssertEqual(otherAPI.delivered,0)
    }
    func testTokenRotationDuringRegistrationRegistersTheNewTokenAndNeverGivesItToCustomServers() async throws {
        let (app,service,_,api,_,_) = try fixture(); defer { app.suspend() }
        api.beforeRegister = {
            api.beforeRegister = nil
            service.receivedDeviceToken(Data(repeating:2,count:32))
        }
        service.receivedDeviceToken(Data(repeating:1,count:32)); service.activate()
        try await wait { api.registrations.count == 2 }
        XCTAssertEqual(api.registrations.map(\.token),[String(repeating:"01",count:32),String(repeating:"02",count:32)])
        let (custom,customService,_,customAPI,_,invite) = try fixture(server:"server.invalid"); defer { custom.suspend() }
        customService.receivedDeviceToken(Data(repeating:3,count:32)); customService.activate()
        try await wait { customAPI.polls == 1 }
        XCTAssertTrue(customAPI.registrations.isEmpty); XCTAssertFalse(customService.receive(payload(invite)))
        XCTAssertTrue(custom.journal.isEmpty)
    }
    func testDeletedKeyCannotBePolledAfterAnInflightRegistrationAndUnsubscribesAfterDurableDeletion() async throws {
        let (app,service,inbox,api,access,invite) = try fixture(); defer { app.suspend() }
        XCTAssertTrue(service.receive(payload(invite)))
        api.beforeRegister = {
            api.beforeRegister = nil; app.removeKey(invite.id)
            XCTAssertTrue(access.state?.guests.isEmpty == true)
        }
        service.receivedDeviceToken(Data(repeating:1,count:32)); service.activate()
        try await wait { api.removed == 1 }
        XCTAssertEqual(api.polls,0); XCTAssertTrue(app.guests.isEmpty); XCTAssertTrue(inbox.state.events.isEmpty)
        XCTAssertFalse(service.receive(payload(invite))); XCTAssertTrue(app.journal.isEmpty)
    }
    func testForgedCipherRetainsHintAndNeverAcknowledgesOrRunsAnAction() async throws {
        let (app,service,inbox,api,_,invite) = try fixture(); defer { app.suspend() }
        XCTAssertFalse(service.receive(payload(invite,type:"fire")))
        XCTAssertTrue(service.receive(payload(invite)))
        api.cipher = try GuestMessageCrypto.seal("Чужое сообщение",bundleKey:Data(repeating:99,count:32))
        service.activate(); try await wait { api.polls == 1 }; await Task.yield(); await Task.yield()
        XCTAssertEqual(api.delivered,0); XCTAssertTrue(app.incomingMessages.isEmpty)
        XCTAssertEqual(inbox.state.events.count,1); XCTAssertTrue(app.journal.isEmpty)
    }
    func testAllInstalledKeysAreRegisteredAndPolledBeyondTheFirstBoundedBatch() async throws {
        let access = PushAccessMemory()
        let guests = try (1...11).map { index in
            SavedGuest(invite:try GuestInvite.parse("https://entrixy.com/key#"+GuestCrypto.base64URL(Data(repeating:UInt8(index),count:24))+GuestCrypto.base64URL(Data(repeating:UInt8(index+20),count:32))))
        }
        access.state = SavedState(identity:Data(repeating:19,count:32),guests:guests)
        let (app,service,_,api,_,_) = try fixture(access:access); defer { app.suspend() }
        service.receivedDeviceToken(Data(repeating:1,count:32)); service.activate()
        try await wait { api.registeredIDs.count == 11 && api.polls == 11 }
        XCTAssertEqual(Set(api.registeredIDs),Set(guests.map(\.id)))
        XCTAssertEqual(api.registrations.count,11); XCTAssertTrue(app.journal.isEmpty)
    }
}
