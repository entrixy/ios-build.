import Foundation

public struct PassedAccess: Codable, Identifiable, Equatable {
    public enum State: String, Codable { case draft, available, awaitingOwner, active, unavailable, revoking, revoked }
    public struct Part: Codable, Equatable {
        public let sourceID: String
        public var objects: [String: KeyObjectAccess]
        public let baselineGroups: [String]
        public var code: String?
        public var sent = false
        public var state: State = .draft
        public var revokeSent = false
        public var childID: Int?
        public var pendingEdit: [String: KeyObjectAccess]?
        public var editSent: Bool?
    }
    public let id: UUID
    public let server: String
    public var label: String
    public let secret: Data
    // Android keeps the group secret/name, but not a second copy of this cipher.
    // An imported, already-created group must never fabricate its first message.
    public let welcomeCipher: String?
    public var group: String?
    public var parts: [Part]
    public let created: Date

    public init(server: String, label: String, welcome: String, objects: [String: [Int: KeyObjectAccess]], snapshots: [String: PassSnapshot],from: String = "") throws {
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label.utf8.count <= 512,
              welcome.utf8.count <= 2048, from.utf8.count <= 512, (1...16).contains(objects.count) else { throw GuestCrypto.Failure.invalidEnvelope }
        id = UUID(); self.server = try GuestInvite.normalizeServer(server); self.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        secret = GuestCrypto.randomBytes(count: 32); created = Date()
        welcomeCipher = try GuestCrypto.encrypt(key: secret, plaintext: JSONSerialization.data(withJSONObject: ["from": from, "text": welcome], options: .sortedKeys))
        parts = try objects.keys.sorted().map { source in
            guard let selected = objects[source], !selected.isEmpty, let snapshot = snapshots[source] else { throw GuestCrypto.Failure.invalidEnvelope }
            var inherited: [String:KeyObjectAccess] = [:]
            for (id, settings) in selected {
                try settings.validate()
                guard let allow = snapshot.allowance[id], allow.canPass,
                      settings.depth < allow.depth, settings.pool <= max(1, allow.poolLeft - 1) else { throw GuestCrypto.Failure.invalidEnvelope }
                inherited[String(id)] = try KeyObjectAccess(nativeOnly:allow.nativeOnly,depth:settings.depth,pool:settings.pool)
            }
            return Part(sourceID: source, objects:inherited,
                baselineGroups: Array(Set(snapshot.invitations.map(\.group) + snapshot.children.map(\.group))).sorted())
        }
    }
    public init(importing material: AndroidPassedAccessMaterial, source: GuestInvite, snapshot: PassSnapshot, defaultLabel: String) throws {
        guard material.server == source.server else { throw GuestCrypto.Failure.invalidEnvelope }
        _ = try DelegationLink(server:material.server,group:material.group,secret:material.secret)
        server = material.server; group = material.group; secret = material.secret
        label = material.label ?? defaultLabel; created = material.created; welcomeCipher = nil
        let value = String(GuestCrypto.hash(Data(("entrixy-android-pass-v1|" + server + "|" + material.group).utf8)).prefix(32))
        var text = ""
        for (i,c) in value.enumerated() { if [8,12,16,20].contains(i) { text.append("-") }; text.append(c) }
        id = UUID(uuidString:text)!
        parts = []
        try recoverPart(source:source,snapshot:snapshot)
        try validate()
    }
    public mutating func recoverPart(source: GuestInvite, snapshot: PassSnapshot) throws {
        guard source.server == server, let group, parts.count < 16,
              !parts.contains(where: { $0.sourceID == source.id }) else { throw GuestCrypto.Failure.invalidEnvelope }
        let invitations = snapshot.invitations.filter { $0.group == group }, children = snapshot.children.filter { $0.group == group }
        guard invitations.count <= 1, children.count <= 1,
              children.first != nil || invitations.first?.status == "new",
              let objects = children.first?.objects ?? invitations.first?.objects, !objects.isEmpty else { throw GuestCrypto.Failure.invalidEnvelope }
        var next = self
        var part = Part(sourceID:source.id,objects:objects,baselineGroups:[])
        part.code = invitations.first?.code; part.sent = true; part.state = .unavailable
        next.parts.append(part)
        try next.reconcile(snapshot,sourceID:source.id)
        try next.validate(); self = next
    }
    public func validate() throws {
        guard server == (try GuestInvite.normalizeServer(server)), secret.count == 32, (1...16).contains(parts.count),
              Set(parts.map(\.sourceID)).count == parts.count, !label.isEmpty, label.utf8.count <= 512,
              group == nil || DelegationLink.code(group!), created.timeIntervalSinceReferenceDate.isFinite else { throw GuestCrypto.Failure.invalidEnvelope }
        if let welcomeCipher { _ = try GuestCrypto.decrypt(key: secret, envelope: welcomeCipher) }
        else { guard group != nil else { throw GuestCrypto.Failure.invalidEnvelope } }
        for part in parts {
            guard !part.sourceID.isEmpty, !part.objects.isEmpty, part.objects.count <= 1000,
                  part.code == nil || DelegationLink.code(part.code!), part.baselineGroups.count <= 5050,
                  part.baselineGroups.allSatisfy(DelegationLink.code), part.childID == nil || part.childID! > 0 else { throw GuestCrypto.Failure.invalidEnvelope }
            for map in [part.objects, part.pendingEdit].compactMap({ $0 }) {
                for (id, value) in map { guard let id = Int(id), id > 0 else { throw GuestCrypto.Failure.invalidEnvelope }; try value.validate() }
            }
        }
    }
    public var link: DelegationLink? {
        guard let group, parts.allSatisfy({ [.available, .awaitingOwner, .active].contains($0.state) && $0.pendingEdit == nil }) else { return nil }
        return try? DelegationLink(server: server, group: group, secret: secret)
    }
    public func createRequest(part index: Int) throws -> Data {
        try validate()
        guard parts.indices.contains(index), parts[index].sent, parts[index].state == .draft,
              group != nil || index == 0 else { throw GuestCrypto.Failure.invalidEnvelope }
        var body: [String: Any] = ["objects": parts[index].objects.keys.sorted().map { parts[index].objects[$0]!.json(id: Int($0)!) }]
        if let group { body["grp"] = group }
        else {
            guard let welcomeCipher else { throw GuestCrypto.Failure.invalidEnvelope }
            body["welcome_cipher"] = welcomeCipher
        }
        return try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
    }
    public mutating func addPart(sourceID: String,objects: [Int:KeyObjectAccess],snapshot: PassSnapshot) throws {
        guard group != nil, parts.count < 16, !parts.contains(where:{ $0.sourceID == sourceID }), !sourceID.isEmpty,
              !objects.isEmpty, objects.count <= 1000 else { throw GuestCrypto.Failure.invalidEnvelope }
        var inherited: [String:KeyObjectAccess] = [:]
        for (id,value) in objects {
            try value.validate()
            guard id > 0, let allow = snapshot.allowance[id], allow.canPass,
                  value.depth < allow.depth, value.pool <= max(1,allow.poolLeft - 1) else { throw GuestCrypto.Failure.invalidEnvelope }
            inherited[String(id)] = try KeyObjectAccess(nativeOnly:allow.nativeOnly,depth:value.depth,pool:value.pool)
        }
        var next = self
        next.parts.append(Part(sourceID:sourceID,objects:inherited,baselineGroups:Array(Set(snapshot.invitations.map(\.group) + snapshot.children.map(\.group))).sorted()))
        try next.validate(); self = next
    }
    public mutating func acceptCreateReply(_ data: Data, part index: Int) throws {
        guard parts.indices.contains(index), parts[index].sent,
              let row = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let group = row["grp"] as? String, DelegationLink.code(group),
              self.group == nil || self.group == group, let code = row["code"] as? String, DelegationLink.code(code) else { throw GuestCrypto.Failure.invalidEnvelope }
        self.group = group; parts[index].code = code
    }
    public mutating func reconcile(_ snapshot: PassSnapshot, sourceID: String) throws {
        guard let index = parts.firstIndex(where: { $0.sourceID == sourceID }) else { return }
        if parts[index].state == .revoked { return }
        guard parts[index].sent || parts[index].code != nil else { return }
        if group == nil && index == 0 && parts[index].sent {
            let candidates = snapshot.invitations.filter { $0.status == "new" && !parts[index].baselineGroups.contains($0.group) && $0.objects == parts[index].objects }
            guard candidates.count <= 1 else { throw GuestCrypto.Failure.invalidEnvelope }
            if let candidate = candidates.first { group = candidate.group; parts[index].code = candidate.code }
        }
        guard let group else { return }
        let invitations = snapshot.invitations.filter { $0.group == group }
        let children = snapshot.children.filter { $0.group == group }
        guard invitations.count <= 1, children.count <= 1 else { throw GuestCrypto.Failure.invalidEnvelope }
        if let invite = invitations.first {
            guard parts[index].code == nil || parts[index].code == invite.code else { throw GuestCrypto.Failure.invalidEnvelope }
            parts[index].code = invite.code
            if invite.status == "cancelled" && children.isEmpty { parts[index].state = .revoked; return }
        }
        if parts[index].state == .revoking {
            if children.isEmpty && invitations.first?.status == "redeemed" { parts[index].state = .revoked }
            return
        }
        if children.isEmpty && invitations.first?.status == "redeemed" && parts[index].pendingEdit?.isEmpty == true {
            parts[index].state = .revoked; parts[index].pendingEdit = nil; parts[index].editSent = false; return
        }
        if let child = children.first {
            parts[index].childID = child.id
            if let desired = parts[index].pendingEdit, child.objects == desired { parts[index].objects = desired; parts[index].pendingEdit = nil; parts[index].editSent = false }
            guard child.objects == parts[index].objects else { parts[index].state = .unavailable; return }
            parts[index].state = child.ready ? .active : .awaitingOwner
        } else if let invite = invitations.first, invite.status == "new" {
            if let desired = parts[index].pendingEdit, invite.objects == desired { parts[index].objects = desired; parts[index].pendingEdit = nil; parts[index].editSent = false }
            parts[index].state = invite.objects == parts[index].objects ? .available : .unavailable
        } else { parts[index].state = .unavailable }
    }
    public func vouches(snapshot: PassSnapshot, invite: GuestInvite) throws -> [Data] {
        guard let group, let part = parts.first(where: { $0.sourceID == invite.id }),
              invite.server == server, part.pendingEdit == nil, ![.revoking, .revoked, .unavailable].contains(part.state) else { return [] }
        return try snapshot.children.filter { $0.group == group && !$0.vouched }.compactMap { child in
            guard let sp = child.signPublic, let gp = child.guestPublic, let mac = child.mac,
                  (try? DelegationProof.checkMAC(mac, secret: secret, group: group, signPublic: sp, guestPublic: gp)) == true else { return nil }
            let signature = try DelegationProof.vouch(userKey: invite.userKey, server: server, childID: child.id, signPublic: sp, guestPublic: gp)
            return try JSONSerialization.data(withJSONObject: ["child_id": child.id, "sig": signature, "sign_pub": sp, "guest_pub": gp], options: .sortedKeys)
        }
    }
}
