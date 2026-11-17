import Foundation

/// Encrypted backup carries actual selected samples, never another phone's URIs.
public struct EventSoundBackup: Codable, Equatable {
    public static let events: Set<String> = ["tap","confirm","incall","geo","biometric","message","success","error","widget_fire"]
    public let volume: Float
    public let muted: Set<String>
    public let samples: [String:Data]
    public let unavailableSamples: Set<String>
    public init(volume: Float,muted: Set<String>,samples: [String:Data],unavailableSamples: Set<String> = []) throws {
        self.volume = volume; self.muted = muted; self.samples = samples; self.unavailableSamples = unavailableSamples
        try validate()
    }
    public func validate() throws {
        guard volume.isFinite, (0...1).contains(volume), muted.isSubset(of:Self.events),
              Set(samples.keys).isSubset(of:Self.events), unavailableSamples.isSubset(of:Self.events),
              Set(samples.keys).isDisjoint(with:unavailableSamples),
              samples.values.allSatisfy({ !$0.isEmpty && $0.count <= BackupEnvelope.maxPayloadSize }),
              samples.values.reduce(0,{ $0 + $1.count }) <= BackupEnvelope.maxPayloadSize else { throw GuestCrypto.Failure.invalidEnvelope }
    }
}

public extension AndroidBackupDocument {
    func eventSoundBackup() throws -> EventSoundBackup {
        var volume: Float = 0.1
        if let preference = entries["app_volume"] {
            guard case .float(let value) = preference else { throw GuestCrypto.Failure.invalidEnvelope }
            volume = min(1,max(0,value))
        }
        var muted = Set<String>(), missing = Set<String>()
        for event in EventSoundBackup.events {
            if let preference = entries["mute_" + event] {
                guard case .boolean(let value) = preference else { throw GuestCrypto.Failure.invalidEnvelope }
                if value { muted.insert(event) }
            }
            if let uri = try string("sound_" + event), !uri.isEmpty { missing.insert(event) }
        }
        return try EventSoundBackup(volume:volume,muted:muted,samples:[:],unavailableSamples:missing)
    }
}
