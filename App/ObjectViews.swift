import SwiftUI
import EntrixyCore

struct ObjectAvatar: View {
    @EnvironmentObject private var model: AppModel
    let object: GuestObject
    let guestID: String
    let size: CGFloat
    private var index: Int {
        guard let value = object.avatarType, value.hasPrefix("preset:"),
              let index = Int(value.dropFirst(7)), (0...7).contains(index) else { return 0 }
        return index
    }
    var body: some View {
        Group {
            if object.avatarType == "file",
               let bytes = model.avatars[AvatarCache.key(guestID: guestID, objectID: object.id)],
               let image = UIImage(data: bytes) {
                Image(uiImage: image).resizable().scaledToFill()
            } else { Image("object-\(index + 1)").resizable().scaledToFill() }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.25)).accessibilityHidden(true)
    }
}

struct OwnerObjectAvatar: View {
    let object: OwnerObject
    let masterKey: Data
    let size: CGFloat
    private var index: Int {
        let value = (try? object.metadata(masterKey: masterKey)["avatar_type"] as? String) ?? ""
        guard value.hasPrefix("preset:"), let index = Int(value.dropFirst(7)), (0...7).contains(index) else { return 0 }
        return index
    }
    var body: some View {
        Image("object-\(index + 1)").resizable().scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.25)).accessibilityHidden(true)
    }
}
