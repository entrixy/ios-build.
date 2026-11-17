import Foundation

public extension AndroidBackupDocument {
    func guestDefaults() throws -> OwnerGuestDefaults {
        var result = OwnerGuestDefaults()
        result.ownerName = try string("owner_self_label") ?? ""
        if let raw = try string("default_obj_access") {
            guard var json = try JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [String:Any] else { throw GuestCrypto.Failure.invalidEnvelope }
            json["id"] = 1
            if json["native_only"] == nil { json["native_only"] = 0 }
            if json["depth"] == nil { json["depth"] = 0 }
            if json["pool"] == nil { json["pool"] = 3 }
            guard let rights = try KeyObjectAccess.decode([json])?["1"] else { throw GuestCrypto.Failure.invalidEnvelope }
            result.access = rights
        }
        try result.validate(); return result
    }
    func companies() throws -> [KnownCompany] {
        var values: [KnownCompany] = []
        let rows = try jsonArray("known_orgs",limit:500)
        for row in rows {
            let companyID = try OwnerObject.replyID(row["id"])
            let server = try GuestInvite.normalizeServer((row["host"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? primaryServer())
            var profile: [String:Any] = ["org_id":companyID,"name":row["name"] ?? "","verified":row["verified"] ?? false]
            for key in ["logo","domain"] { if let value = row[key] as? String, !value.isEmpty { profile[key] = value } }
            if let publicKey = try string("org_known_pub_\(companyID)@\(server)") { profile["pubkey"] = publicKey }
            let pending: String?
            if let pendingID = try integer("pending_org_id"), pendingID == Int64(companyID), rows.filter({ $0["id"] as? Int == companyID }).count == 1 { pending = try string("pending_org_code") } else { pending = nil }
            values.append(try KnownCompany(server:server,json:profile,pendingCode:pending.flatMap { $0.isEmpty ? nil : $0 }))
        }
        try KnownCompany.validateDirectory(values)
        return values
    }
}
