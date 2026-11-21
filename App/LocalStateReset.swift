import Foundation
import Security
import UIKit
import UserNotifications
import WidgetKit
import EntrixyCore

/// A retired model cannot put old credentials back after an explicit reset.
/// Identity comparison also rejects writes from another pre-reset model.
final class LocalStateSession: StateStorage {
    private let underlying: StateStorage
    private let lock = NSRecursiveLock()
    private var loaded = false
    private var identity: Data?
    private var replacement: Data?
    private var retired = false
    init(_ underlying: StateStorage) { self.underlying = underlying }
    func load() throws -> SavedState? {
        lock.lock(); defer { lock.unlock() }
        guard !retired else { throw KeychainStore.Failure(status:errSecInteractionNotAllowed) }
        let state = try underlying.load()
        if let state { try Self.validateResetMarker(state) }
        if loaded, state?.identity != identity { throw KeychainStore.Failure(status:errSecInteractionNotAllowed) }
        identity = state?.identity; loaded = true
        return state
    }
    func save(_ state: SavedState) throws {
        lock.lock(); defer { lock.unlock() }
        guard !retired else { throw KeychainStore.Failure(status:errSecInteractionNotAllowed) }
        let current = try load()
        guard current == nil || state.identity == identity else { throw KeychainStore.Failure(status:errSecParam) }
        try Self.validateResetMarker(state)
        try underlying.save(state)
        identity = state.identity
    }
    func erase(confirmedIdentity:Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard let current = try load(), current.identity == confirmedIdentity,
              current.pendingLocalReset != true else { throw KeychainStore.Failure(status:errSecInteractionNotAllowed) }
        var empty = SavedState(identity:GuestCrypto.randomBytes(count:32),guests:[])
        empty.pendingLocalReset = true
        // One atomic Keychain update: never delete first, and never turn a
        // read/write failure into a new usable identity or partial erasure.
        try underlying.save(empty)
        replacement = empty.identity; retired = true
    }
    func cleanupNeeded() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let current = try underlying.load(), current.identity == (replacement ?? identity) else {
            throw KeychainStore.Failure(status:errSecInteractionNotAllowed)
        }
        try Self.validateResetMarker(current)
        // Another fresh model may have completed cleanup and started using its
        // new state. A retired screen must not erase that model's new files.
        return current.pendingLocalReset == true
    }
    func finishCleanup() throws {
        lock.lock(); defer { lock.unlock() }
        guard var current = try underlying.load(), current.identity == (replacement ?? identity),
              current.pendingLocalReset == true, current.guests.isEmpty,
              (current.owners ?? []).isEmpty, current.actionCode == nil else { throw KeychainStore.Failure(status:errSecInteractionNotAllowed) }
        try Self.validateResetMarker(current)
        current.pendingLocalReset = nil
        try underlying.save(current)
        // A model retired by erase stays retired even after cleanup succeeds.
    }
    private static func validateResetMarker(_ state:SavedState) throws {
        guard state.pendingLocalReset == true else { return }
        let encoded = try JSONEncoder().encode(state)
        guard state.identity.count == 32,state.guests.isEmpty,
              let fields = try JSONSerialization.jsonObject(with:encoded) as? [String:Any],
              Set(fields.keys) == Set(["identity","guests","pendingLocalReset"]) else {
            throw KeychainStore.Failure(status:errSecDecode)
        }
    }
}

@MainActor enum AppLocalDataCleanup {
    static func clear(biometricService:String) throws {
        let fm = FileManager.default
        let support = try fm.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
        for name in ["Diagnostics","Promotions","NativePush","EncryptedAvatars","EventSounds"] {
            let url = support.appendingPathComponent(name,isDirectory:true)
            if fm.fileExists(atPath:url.path) { try fm.removeItem(at:url) }
        }
        if let cache = fm.urls(for:.cachesDirectory,in:.userDomainMask).first, fm.fileExists(atPath:cache.path) {
            for url in try fm.contentsOfDirectory(at:cache,includingPropertiesForKeys:nil) { try fm.removeItem(at:url) }
        }
        if let widget = WidgetCatalog.directory, fm.fileExists(atPath:widget.path) { try fm.removeItem(at:widget) }
        let sounds = fm.urls(for:.libraryDirectory,in:.userDomainMask)[0].appendingPathComponent("Sounds",isDirectory:true)
        if fm.fileExists(atPath:sounds.path) {
            for url in try fm.contentsOfDirectory(at:sounds,includingPropertiesForKeys:nil)
                where url.lastPathComponent.hasPrefix("entrixy-") && url.pathExtension == "caf" { try fm.removeItem(at:url) }
        }
        for url in try fm.contentsOfDirectory(at:fm.temporaryDirectory,includingPropertiesForKeys:nil)
            where url.lastPathComponent.hasPrefix("Entrixy-") && url.pathExtension == "eib" { try fm.removeItem(at:url) }
        let status = SecItemDelete([kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:biometricService,kSecAttrAccount as String:"current-set"] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainStore.Failure(status:status) }
        if let bundle = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName:bundle) }
        URLCache.shared.removeAllCachedResponses()
        for cookie in HTTPCookieStorage.shared.cookies ?? [] { HTTPCookieStorage.shared.deleteCookie(cookie) }
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UIApplication.shared.unregisterForRemoteNotifications()
        AppSoundCenter.shared.clearAfterLocalReset()
        WidgetCenter.shared.reloadTimelines(ofKind:WidgetCatalog.kind)
    }
}

extension Notification.Name { static let entrixyLocalResetCompleted = Notification.Name("entrixy.local-reset.completed") }
