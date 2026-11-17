import Foundation

public extension AndroidBackupDocument {
    func ownerLocalConfiguration(localID: Int) throws -> OwnerObjectLocalConfiguration? {
        let fields = ["snap_on_","snap_url_","snap_auth_","snap_val_","snap_hdr_","snap_int_","snap_when_","snap_ct_","hangup_"]
        guard fields.contains(where:{ entries[$0 + String(localID)] != nil }) else { return nil }
        var local = OwnerObjectLocalConfiguration()
        local.hangupSeconds = Int(try integer("hangup_\(localID)") ?? 0)
        var camera = ObjectCameraConfiguration()
        if let on = entries["snap_on_\(localID)"] {
            guard case .boolean(let value) = on else { throw GuestCrypto.Failure.invalidEnvelope }; camera.enabled = value
        }
        camera.url = try string("snap_url_\(localID)") ?? ""
        camera.authType = try string("snap_auth_\(localID)") ?? "none"
        camera.authValue = try string("snap_val_\(localID)") ?? ""
        camera.authHeader = try string("snap_hdr_\(localID)") ?? ""
        camera.intervalSec = Int(try integer("snap_int_\(localID)") ?? 5)
        camera.showWhen = try string("snap_when_\(localID)") ?? "call"
        camera.contentType = try string("snap_ct_\(localID)") ?? "jpeg"
        local.camera = camera; try local.validate()
        return local
    }
}
