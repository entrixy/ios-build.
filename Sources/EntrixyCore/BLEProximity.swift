import Foundation

/// Only verified radio material reaches the automation observer. Names and a
/// public device ID alone cannot authorize proximity or a gate position.
public struct AuthenticatedBLEObservation: Equatable {
    public let deviceID: UInt32
    public let counter: UInt32
    public let sleepSeconds: UInt8?
    public let stateBits: UInt8?
    public var position: String? {
        guard let bits = stateBits, bits & 0x80 == 0 else { return nil }
        if bits & 0x40 != 0 { return bits & 1 != 0 ? "opening" : "closing" }
        return bits & 1 != 0 ? "open" : "closed"
    }
    public var openish: Bool { position == "open" || position == "opening" }
    public static func owner(payload: Data, secret: Data) throws -> Self {
        let advertisement = try BLECrypto.verifyAdvertisement(payload,ownerSecret:secret)
        let state = try BLECrypto.state(payload,stateKey:BLECrypto.stateKey(ownerSecret:secret))
        return Self(deviceID:advertisement.deviceID,counter:advertisement.counter,sleepSeconds:payload.count >= 21 ? advertisement.sleepSeconds : nil,stateBits:state)
    }
    public static func guest(payload: Data, grant: BLEGuestGrant, epoch: UInt64) throws -> Self {
        guard grant.isValid(at:epoch), payload.count == 24, let key = grant.stateKey,
              try BLECrypto.advertisementDeviceID(payload) == grant.deviceID,
              let bits = try BLECrypto.state(payload,stateKey:key) else { throw GuestCrypto.Failure.invalidEnvelope }
        // The guest state MAC covers counter/state, not the advertised sleep
        // byte. Unauthenticated sleep cannot shorten the rearm gap.
        return Self(deviceID:grant.deviceID,counter:UInt32(BLECrypto.unsignedLE(payload[4..<8])),sleepSeconds:nil,stateBits:bits)
    }
}

/// Android BleScanReceiver's 5s RSSI debounce and controller-sleep-aware rearm.
/// The durable armed latch belongs to the app's protected state transaction.
public struct BLEProximityRuntime {
    public struct Sample: Equatable {
        public let observation: AuthenticatedBLEObservation
        public let rssi: Int
        public let lastSeen: TimeInterval
        public let window: TimeInterval
        public func fresh(at now: TimeInterval) -> Bool { now >= lastSeen && now-lastSeen < window }
        public func near(radiusM: Int, at now: TimeInterval) -> Bool { fresh(at:now) && rssi >= BLEProximityRuntime.threshold(radiusM) }
    }
    private struct State { var sample: Sample; var rssiAt: TimeInterval; var continuouslyObserved = true }
    private var states: [String: State] = [:]
    public init() {}
    public static func threshold(_ meters: Int) -> Int {
        switch meters { case ...1: return -45; case ...2: return -55; case ...3: return -65
        case ...5: return -75; case ...10: return -85; case ...20: return -95; default: return -100 }
    }
    public static func window(_ sleepSeconds: UInt8?) -> TimeInterval { sleepSeconds.map { min(60,max(5,Double($0)*5+5)) } ?? 60 }
    public func sample(_ key: String, at now: TimeInterval) -> Sample? {
        guard let state = states[key], state.sample.fresh(at:now) else { return nil }
        return state.sample
    }
    /// True only for a radio gap during continuous observation. Time when the
    /// app was stopped/backgrounded is not evidence that the user left the gate.
    @discardableResult public mutating func receive(key: String, observation: AuthenticatedBLEObservation, rssi: Int, now: TimeInterval) -> Bool {
        guard (-127...20).contains(rssi), now.isFinite, now >= 0 else { return false }
        let old = states[key]
        guard old.map({ now >= $0.sample.lastSeen }) ?? true else { return false }
        let rearm = old.map { $0.continuouslyObserved && now-$0.sample.lastSeen >= $0.sample.window } ?? false
        let keepRSSI = old.map { now-$0.rssiAt < 5 && $0.continuouslyObserved } ?? false
        let sample = Sample(observation:observation,rssi:keepRSSI ? old!.sample.rssi : rssi,lastSeen:now,window:Self.window(observation.sleepSeconds))
        states[key] = State(sample:sample,rssiAt:keepRSSI ? old!.rssiAt : now)
        return rearm
    }
    public mutating func suspend() { for key in Array(states.keys) { states[key]?.continuouslyObserved = false } }
    public mutating func retain(_ keys: Set<String>) { states = states.filter { keys.contains($0.key) } }
}
