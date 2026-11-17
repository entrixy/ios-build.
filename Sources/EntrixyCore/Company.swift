import Foundation

/// Android company links. Server choice is part of the invitation; credentials
/// for a different owner account must never be sent to it.
public struct CompanyInvite: Equatable {
    public let server: String
    public let code: String
    public static func parse(_ text: String) throws -> Self {
        guard let url = URLComponents(string:text.trimmingCharacters(in:.whitespacesAndNewlines)),
              url.user == nil, url.password == nil, url.fragment == nil else { throw GuestCrypto.Failure.invalidEnvelope }
        let query = url.queryItems ?? []
        guard Set(query.map(\.name)).count == query.count else { throw GuestCrypto.Failure.invalidEnvelope }
        let code: String, server: String
        if url.scheme == "entrixy", ["company","org"].contains(url.host ?? ""), url.port == nil, url.path.isEmpty || url.path == "/" {
            code = query.first(where:{ $0.name == "code" })?.value ?? ""
            server = query.first(where:{ $0.name == "h" })?.value ?? "entrixy.com"
        } else if url.scheme == "https", let host = url.host {
            let parts = url.path.split(separator:"/",omittingEmptySubsequences:false)
            guard parts.count == 3, parts[0].isEmpty, ["c","o"].contains(String(parts[1])) else { throw GuestCrypto.Failure.invalidEnvelope }
            code = String(parts[2]); server = query.first(where:{ $0.name == "h" })?.value ?? host + (url.port.map { ":\($0)" } ?? "")
        } else { throw GuestCrypto.Failure.invalidEnvelope }
        guard validCode(code) else { throw GuestCrypto.Failure.invalidEnvelope }
        return Self(server:try GuestInvite.normalizeServer(server),code:code)
    }
    public static func validCode(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }
}

public struct KnownCompany: Codable, Equatable, Identifiable {
    public let server: String
    public let companyID: Int
    public var name: String
    public var domain: String?
    public var logo: String?
    public var verified: Bool
    public var publicKey: Data?
    public var pendingCode: String?
    public var id: String { server + ":" + String(companyID) }
    /// OrgVerify.kt: proof branding is provided only by the trusted server.
    public var proven: Bool { server == "entrixy.com" && verified }
    public init(server: String, json: [String:Any], pendingCode: String? = nil) throws {
        self.server = try GuestInvite.normalizeServer(server)
        companyID = try OwnerObject.replyID(json["org_id"])
        name = json["name"] as? String ?? ""
        domain = json["domain"] as? String
        logo = json["logo"] as? String
        verified = (json["verified"] as? NSNumber)?.boolValue == true
        if let encoded = json["pubkey"] as? String, !encoded.isEmpty {
            guard let bytes = Data(base64Encoded:encoded), bytes.count == 32 else { throw GuestCrypto.Failure.invalidKey }
            publicKey = bytes
        }
        self.pendingCode = pendingCode
        try validate()
    }
    public func validate() throws {
        guard try GuestInvite.normalizeServer(server) == server, companyID > 0,
              !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, name.utf8.count <= 1024,
              (domain?.utf8.count ?? 0) <= 512, (logo?.utf8.count ?? 0) <= 1024,
              publicKey == nil || publicKey?.count == 32,
              pendingCode == nil || CompanyInvite.validCode(pendingCode!) else { throw GuestCrypto.Failure.invalidEnvelope }
        if let logo, !logo.isEmpty {
            guard logo.hasPrefix("/img/org/"), !logo.contains(".."), !logo.contains("?"), !logo.contains("#"), !logo.contains("\\") else { throw GuestCrypto.Failure.invalidEnvelope }
        }
    }
    public static func validateDirectory(_ values: [Self]) throws {
        guard values.count <= 500, Set(values.map(\.id)).count == values.count else { throw GuestCrypto.Failure.invalidEnvelope }
        for value in values { try value.validate() }
    }
}

/// Explicitly associated and pinned when granting access. A later server
/// profile refresh cannot replace the key used to verify an issued grant;
/// Android explicitly repins when the owner opens a new company request.
public struct CompanyGrant: Codable, Equatable {
    public let companyID: Int
    public var publicKey: Data?
    public let inviteCode: String?
    public var labels: [String:String]
    public init(profile: KnownCompany, labels: [String:String]) throws {
        try profile.validate()
        companyID = profile.companyID; publicKey = profile.publicKey
        inviteCode = profile.pendingCode; self.labels = labels
    }
    public func validate(numberIDs: [Int]) throws {
        guard companyID > 0, publicKey == nil || publicKey?.count == 32,
              inviteCode == nil || CompanyInvite.validCode(inviteCode!),
              Set(labels.keys) == Set(numberIDs.map(String.init)), labels.values.allSatisfy({ $0.count <= 64 }) else { throw GuestCrypto.Failure.invalidEnvelope }
    }
}

public struct VerifiedCompanyPress {
    public let nonce: String
    public let actor: String
}

public enum CompanyPress {
    public static func verify(_ press: [String:Any], publicKey: Data, keyID: Int, numberID: Int,
                              numberIDs: [Int], expectedAction: String, now: Int64 = Int64(Date().timeIntervalSince1970)) throws -> VerifiedCompanyPress {
        guard expectedAction.isEmpty, publicKey.count == 32, numberID > 0, numberIDs.contains(numberID),
              let org = press["org"] as? [String:Any], let domain = org["domain"] as? String,
              !domain.isEmpty, domain.utf8.count <= 253, domain.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
              let ts = org["ts"] as? Int64, ts > 0, abs(Double(ts)-Double(now)) <= 600,
              let nonce = org["nonce"] as? String, nonce.utf8.count == 32,
              nonce.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let body = org["body"] as? String, body.utf8.count <= 65536,
              let encoded = org["sig"] as? String, let signature = Data(base64Encoded:encoded), signature.count == 64 else { throw GuestCrypto.Failure.invalidEnvelope }
        let material = Data("\(domain).\(ts).\(nonce).\(GuestCrypto.hash(Data(body.utf8)))".utf8)
        guard try GuestCrypto.verify(signature:signature, material:material, publicKey:publicKey),
              let json = try JSONSerialization.jsonObject(with:Data(body.utf8)) as? [String:Any],
              try OwnerObject.replyID(json["key_ref"]) == keyID,
              let actor = json["actor"] as? String, !actor.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              actor.utf8.count <= 1024 else { throw GuestCrypto.Failure.invalidKey }
        let selected: Int
        if let raw = json["number_id"], (raw as? Int) != 0 { selected = try OwnerObject.replyID(raw) } else { selected = 0 }
        guard selected == numberID || (selected == 0 && numberIDs == [numberID]) else { throw GuestCrypto.Failure.invalidKey }
        return VerifiedCompanyPress(nonce:nonce,actor:actor)
    }
}

public extension OwnerIssuedKey {
    static func forCompany(owner: OwnerAccount, profile: KnownCompany, numberIDs: [Int], calls: [String:OwnerCallPreference] = [:]) throws -> Self {
        guard profile.server == owner.server,
              !(owner.issuedKeys ?? []).contains(where:{ $0.company?.companyID == profile.companyID && $0.state != .revoked }) else { throw GuestCrypto.Failure.invalidEnvelope }
        try checkCompanyScope(owner:owner,numberIDs:numberIDs)
        let rights = try Dictionary(uniqueKeysWithValues:numberIDs.map { ($0,try KeyObjectAccess(depth:0,pool:1)) })
        var settings = OwnerKeyConfiguration(); settings.calls = calls
        var key = try Self(owner:owner,label:profile.name,numberIDs:numberIDs,welcome:"",nativeOnly:false,confirmation:false,access:rights,settings:settings)
        key.company = try CompanyGrant(profile:profile,labels:companyLabels(owner:owner,numberIDs:numberIDs))
        return key
    }
    static func checkCompanyScope(owner: OwnerAccount, numberIDs: [Int]) throws {
        let selected = (owner.objects ?? []).filter { numberIDs.contains($0.numberID ?? -1) }
        guard !numberIDs.isEmpty, selected.count == numberIDs.count, selected.allSatisfy({ $0.kind == "call" && $0.pending == nil && $0.available != false }) else { throw GuestCrypto.Failure.invalidEnvelope }
    }
    static func companyLabels(owner: OwnerAccount, numberIDs: [Int]) throws -> [String:String] {
        try Dictionary(uniqueKeysWithValues:numberIDs.map { number in
            guard let object = owner.objects?.first(where:{ $0.numberID == number }),
                  let label = try object.metadata(masterKey:owner.masterKey)["label"] as? String else { throw GuestCrypto.Failure.invalidEnvelope }
            return (String(number),String(label.prefix(64)))
        })
    }
    /// A duplicate company create can return a pre-existing server key whose
    /// signing identity differs. Never adopt its ID for our newly prepared key.
    mutating func acceptCreationReply(_ json: [String:Any]) throws {
        guard pending == .keyCreate, sent, (json["merged"] as? Int ?? 0) == 0 else { throw GuestCrypto.Failure.invalidEnvelope }
        if let company { guard (json["org_id"] as? Int) == company.companyID else { throw GuestCrypto.Failure.invalidEnvelope } }
        keyID = try OwnerObject.replyID(json["id"])
    }
}
