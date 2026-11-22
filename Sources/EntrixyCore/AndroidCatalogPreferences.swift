import Foundation

public extension AndroidBackupDocument {
    /// Translate Android action keys to the exact imported owner/guest scopes.
    /// This changes presentation only, including objects not downloaded yet.
    func catalogPreferences(owners: [OwnerAccount]) throws -> ObjectCatalogPreferences {
        let guests = try guests()
        let guestIDs = try Dictionary(uniqueKeysWithValues: guests.map {
            ($0.localID, try GuestSigningIdentity(server:$0.server,userKey:$0.userKey).id)
        })
        let ownedTargets = Set(owners.flatMap { owner in
            (owner.objects ?? []).map { ObjectReference.owned(server:owner.server,objectID:$0.id) }
        })
        var own: [String:ObjectReference] = [:]
        let rows = try jsonArray("host_numbers")
        let bluetooth = try jsonArray("ble_objects")
        for (prefix,items) in [("h",rows),("b",bluetooth)] {
            for row in items {
                let localID = try OwnerObject.replyID(row["id"])
                let ref = try objectReference(localID:localID,fallbackServer:row["host"] as? String)
                let target = ObjectReference.owned(server:ref.server,objectID:AndroidOwnerAdapter.objectID(server:ref.server,numberID:ref.numberID))
                if ownedTargets.contains(target) { own[prefix + String(localID)] = target }
            }
        }
        func received(_ key: String) -> ObjectReference? {
            let body: Substring, separator: Character, kind: String
            if key.hasPrefix("gb") { body = key.dropFirst(2); separator = "b"; kind = "b:" }
            else if key.hasPrefix("g") { body = key.dropFirst(); separator = "n"; kind = "n:" }
            else { return nil }
            let parts = body.split(separator:separator,omittingEmptySubsequences:false)
            guard parts.count == 2, let localID = Int(parts[0]), let numberID = Int(parts[1]),
                  localID > 0, (1...Int(Int32.max)).contains(numberID), let guestID = guestIDs[localID] else { return nil }
            return .received(guestID:guestID,objectID:kind + String(numberID))
        }
        var result = ObjectCatalogPreferences(), seen = Set<ObjectReference>()
        var order = try string("all_action_order")
        if order == nil {
            let ownOrder = try string("object_order")?.split(separator:",").map { "h" + $0.trimmingCharacters(in:.whitespacesAndNewlines) } ?? []
            let guestOrder = try string("guest_action_order") ?? ""
            order = (ownOrder + [guestOrder]).joined(separator:",")
        }
        guard (order?.utf8.count ?? 0) <= 262144 else { throw GuestCrypto.Failure.invalidEnvelope }
        for raw in order?.split(separator:",") ?? [] {
            let key = raw.trimmingCharacters(in:.whitespacesAndNewlines)
            if let target = own[key] ?? received(key), seen.insert(target).inserted { result.order.append(target) }
        }
        if let raw = try string("overrides") {
            guard raw.utf8.count <= 2_097_152,
                  let entries = try JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [String:[String:Any]],
                  entries.count <= 4000 else { throw GuestCrypto.Failure.invalidEnvelope }
            for (key,fields) in entries {
                guard let target = received(key) else { continue }
                if let label = fields["label"] as? String { try result.rename(target,label:label) }
                if let avatar = fields["avatar"] as? String, avatar.hasPrefix("preset:"),
                   let index = Int(avatar.dropFirst(7)), (0...7).contains(index) {
                    var value = result.presentation(for:target); value.avatarPreset = index; result.received[target.id] = value
                }
                // Android absolute image paths are not image bytes. Never read
                // an arbitrary same-named path on the importing iPhone.
            }
        }
        if let entry = entries["hidden_objects"] {
            guard case .strings(let hidden) = entry, hidden.count <= 4000 else { throw GuestCrypto.Failure.invalidEnvelope }
            for key in hidden {
                let parts = key.split(separator:"_",omittingEmptySubsequences:false)
                guard parts.count == 2 else { continue }
                let action = parts[1].hasPrefix("b") ? "gb" + parts[0] + parts[1] : "g" + parts[0] + "n" + parts[1]
                if let target = received(action) { try result.hide(target) }
            }
        }
        try result.validate()
        return result
    }
}
