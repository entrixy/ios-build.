import Foundation

/// Add missing protected material without replacing an existing owner's identity,
/// permissions or unfinished mutation. Conflicts are discovered before host_claim.
public extension OwnerAccount {
    func mergingBackup(_ source: OwnerAccount) throws -> OwnerAccount {
        try validate(); try source.validate()
        guard server == source.server, masterKey == source.masterKey, credentials == source.credentials else { throw GuestCrypto.Failure.invalidKey }
        var merged = self
        merged.reservedGuestIDs = Array(Set((reservedGuestIDs ?? []) + (source.reservedGuestIDs ?? []))).sorted()
        func sameSecret(_ first: String?, _ second: String?) throws {
            if let first, let second {
                guard try GuestCrypto.decrypt(key: masterKey, envelope: first) == GuestCrypto.decrypt(key: masterKey, envelope: second) else { throw GuestCrypto.Failure.invalidKey }
            }
        }
        func object(_ current: OwnerObject, _ incoming: OwnerObject) throws -> OwnerObject {
            guard current.id == incoming.id, current.kind == incoming.kind,
                  current.numberID == nil || incoming.numberID == nil || current.numberID == incoming.numberID,
                  current.bleDeviceID == incoming.bleDeviceID else { throw GuestCrypto.Failure.invalidEnvelope }
            try sameSecret(current.wrappedKey, incoming.wrappedKey)
            try sameSecret(current.wrappedBLESecret, incoming.wrappedBLESecret)
            try sameSecret(current.wrappedSocketSecret, incoming.wrappedSocketSecret)
            if incoming.pending != nil && (current.pending != incoming.pending || current.cipher != incoming.cipher) {
                guard incoming.pending == .create, incoming.sent, current.numberID != nil,
                      incoming.cipher == current.cipher, current.pending == nil else { throw GuestCrypto.Failure.invalidEnvelope }
            }
            if let first = current.localPolicy, let second = incoming.localPolicy, first != second { throw GuestCrypto.Failure.invalidEnvelope }
            var result = current
            if current.pending == .create, incoming.pending == nil, let numberID = incoming.numberID, current.cipher == incoming.cipher {
                result.numberID = numberID; result.pending = nil; result.sent = false; result.revision = incoming.revision
            } else if result.pending != nil { result.sent = current.sent || incoming.sent }
            result.wrappedBLESecret = current.wrappedBLESecret ?? incoming.wrappedBLESecret
            result.wrappedSocketSecret = current.wrappedSocketSecret ?? incoming.wrappedSocketSecret
            result.localPhone = current.localPhone ?? incoming.localPhone
            result.localPolicy = current.localPolicy ?? incoming.localPolicy
            var proofs: [String] = []
            for proof in (incoming.bleProofs ?? []) + (current.bleProofs ?? []) {
                proofs.removeAll { $0 == proof }; proofs.append(proof)
            }
            if current.bleProofs != nil || incoming.bleProofs != nil { result.bleProofs = Array(proofs.suffix(64)) }
            return result
        }
        var active = objects ?? [], archived = bleArchivedObjects ?? []
        for incoming in source.objects ?? [] {
            if let index = archived.firstIndex(where: { $0.id == incoming.id }) {
                _ = try object(archived[index], incoming)
                continue // A restored old copy cannot resurrect a deleted object.
            }
            if let index = active.firstIndex(where: { $0.id == incoming.id }) { active[index] = try object(active[index], incoming) }
            else {
                guard !active.contains(where: { $0.numberID != nil && $0.numberID == incoming.numberID }) else { throw GuestCrypto.Failure.invalidEnvelope }
                active.append(incoming)
            }
        }
        for incoming in source.bleArchivedObjects ?? [] {
            if let index = active.firstIndex(where: { $0.id == incoming.id }) {
                _ = try object(active[index], incoming); active.remove(at: index)
            }
            if let index = archived.firstIndex(where: { $0.id == incoming.id }) { _ = try object(archived[index], incoming) }
            else { archived.append(incoming) }
        }
        merged.objects = active; merged.bleArchivedObjects = archived

        var issued = issuedKeys ?? []
        for incoming in source.issuedKeys ?? [] {
            if let index = issued.firstIndex(where: { $0.id == incoming.id }) {
                var current = issued[index]
                let first = try current.secrets(masterKey: masterKey), second = try incoming.secrets(masterKey: masterKey)
                guard first.userKey == second.userKey, first.bundleKey == second.bundleKey,
                      current.guestID == incoming.guestID, current.nativeOnly == incoming.nativeOnly,
                      current.keyID == nil || incoming.keyID == nil || current.keyID == incoming.keyID else { throw GuestCrypto.Failure.invalidKey }
                if incoming.state == .revoked || current.state == .revoked {
                    current.state = .revoked; current.pending = nil; current.pendingMode = nil; current.sent = false
                } else {
                    guard current.numberIDs == incoming.numberIDs, current.grantedAccess == incoming.grantedAccess,
                          current.bundleCipher == incoming.bundleCipher else { throw GuestCrypto.Failure.invalidEnvelope }
                    if incoming.pending != nil && (current.pending != incoming.pending || current.pendingMode != incoming.pendingMode) {
                        guard incoming.pending == .keyCreate, incoming.sent, current.keyID != nil, current.pending == nil else { throw GuestCrypto.Failure.invalidEnvelope }
                    }
                }
                if current.state != .revoked {
                    if current.pending == .keyCreate, incoming.pending == nil, let keyID = incoming.keyID {
                        current.keyID = keyID; current.pending = nil; current.sent = false; current.requestedAccess = nil
                        current.effectiveNumberIDs = incoming.effectiveNumberIDs; current.access = incoming.access; current.state = incoming.state
                    } else if current.pending != nil { current.sent = current.sent || incoming.sent }
                }
                issued[index] = current
            } else {
                guard !issued.contains(where: { ($0.keyID != nil && $0.keyID == incoming.keyID) || $0.guestID == incoming.guestID }) else { throw GuestCrypto.Failure.invalidEnvelope }
                issued.append(incoming)
            }
        }
        merged.issuedKeys = issued
        var delegated = delegatedKeys ?? []
        for incoming in source.delegatedKeys ?? [] {
            if let index = delegated.firstIndex(where: { $0.id == incoming.id }) {
                let current = delegated[index]
                try sameSecret(current.wrappedBundleKey, incoming.wrappedBundleKey)
                guard current.keyID == incoming.keyID, current.parentKeyID == incoming.parentKeyID, current.rootID == incoming.rootID,
                      current.guestID == incoming.guestID, current.signPublic == incoming.signPublic,
                      current.guestPublic == incoming.guestPublic, current.vouch == incoming.vouch,
                      current.numberIDs == incoming.numberIDs, current.access == incoming.access,
                      current.bundleCipher == incoming.bundleCipher else { throw GuestCrypto.Failure.invalidEnvelope }
                if incoming.revocationPending == true && current.revocationPending != true { throw GuestCrypto.Failure.invalidEnvelope }
                delegated[index].sent = current.sent || incoming.sent
                if current.revocationPending == true { delegated[index].revocationSent = current.revocationSent == true || incoming.revocationSent == true }
                if incoming.state == .revoked { delegated[index].state = .revoked; delegated[index].revocationPending = false; delegated[index].revocationSent = false }
            } else {
                guard !delegated.contains(where: { $0.guestID == incoming.guestID }) else { throw GuestCrypto.Failure.invalidEnvelope }
                delegated.append(incoming)
            }
        }
        merged.delegatedKeys = delegated
        merged.bleRevocations = try BLERevocation.merge(source.bleRevocations ?? [], into: bleRevocations ?? [], limit: 2000)
        var pairings = blePairings ?? []
        for incoming in source.blePairings ?? [] {
            if let index = pairings.firstIndex(where: { $0.id == incoming.id }) {
                let current = pairings[index]
                try sameSecret(current.wrappedSecret, incoming.wrappedSecret)
                guard current.deviceID == incoming.deviceID, current.peerPublic == incoming.peerPublic,
                      current.packet == incoming.packet else { throw GuestCrypto.Failure.invalidEnvelope }
                let rank: [BLEPairingRecord.Phase: Int] = [.prepared: 0, .sent: 1, .confirmed: 2]
                if rank[incoming.phase]! > rank[current.phase]! { pairings[index] = incoming }
            } else {
                guard !pairings.contains(where: { $0.deviceID == incoming.deviceID }) else { throw GuestCrypto.Failure.invalidEnvelope }
                pairings.append(incoming)
            }
        }
        let activeIDs = Set(active.map(\.id))
        for index in pairings.indices { if let id = pairings[index].objectID, !activeIDs.contains(id) { pairings[index].objectID = nil } }
        merged.blePairings = pairings
        let knownKeys = Set((issuedKeys ?? []).map(\.id) + (delegatedKeys ?? []).map(\.id))
        var pending = bleRestorePending ?? [], scopes = bleRestoreObjectIDs ?? [:]
        for id in source.bleRestorePending ?? [] {
            let root = source.issuedKeys?.first { $0.id == id }
            let leaf = source.delegatedKeys?.first { $0.id == id }
            guard root != nil || leaf != nil else { throw GuestCrypto.Failure.invalidEnvelope }
            let rootID = root?.id ?? leaf!.rootID
            let guestIDs = Set([root?.guestID, leaf?.guestID].compactMap { $0 } + (source.delegatedKeys ?? []).filter { $0.rootID == rootID }.map(\.guestID))
            for decision in bleRevocations ?? [] where decision.revoked && guestIDs.contains(Int(decision.guestID)) {
                let previous = source.bleRevocations?.first { $0.id == decision.id }?.version ?? 0
                guard decision.version <= previous else { throw GuestCrypto.Failure.invalidEnvelope }
            }
            if knownKeys.contains(id) {
                guard pending.contains(id), scopes[id.uuidString] == source.bleRestoreObjectIDs?[id.uuidString] else { throw GuestCrypto.Failure.invalidEnvelope }
            } else {
                if !pending.contains(id) { pending.append(id) }
                if let scope = source.bleRestoreObjectIDs?[id.uuidString] { scopes[id.uuidString] = scope }
            }
        }
        merged.bleRestorePending = pending; merged.bleRestoreObjectIDs = scopes
        var android = androidKeys ?? []
        for incoming in source.androidKeys ?? [] {
            if let index = android.firstIndex(where: { $0.serverKeyID == incoming.serverKeyID }) {
                let current = android[index]
                try sameSecret(current.wrappedBundleKey, incoming.wrappedBundleKey)
                guard current.userKey == nil || incoming.userKey == nil || current.userKey == incoming.userKey,
                      current.guestID == nil || incoming.guestID == nil || current.guestID == incoming.guestID,
                      current.signPublic == nil || incoming.signPublic == nil || current.signPublic == incoming.signPublic else { throw GuestCrypto.Failure.invalidKey }
                android[index] = AndroidOwnerKeyMaterial(serverKeyID: current.serverKeyID, userKey: current.userKey ?? incoming.userKey,
                    wrappedBundleKey: current.wrappedBundleKey ?? incoming.wrappedBundleKey, guestID: current.guestID ?? incoming.guestID,
                    label: current.label, signPublic: current.signPublic ?? incoming.signPublic)
            } else { android.append(incoming) }
        }
        merged.androidKeys = android
        try merged.validate()
        return merged
    }
}
