import SwiftUI
import EntrixyCore

struct ObjectAvatar: View {
    @EnvironmentObject private var model: AppModel
    let object: GuestObject
    let guestID: String
    let size: CGFloat
    private var target: ObjectReference { .received(guestID: guestID, objectID: object.id) }
    private var index: Int {
        if let preset = model.objectPreferences.presentation(for: target).avatarPreset { return preset }
        guard let value = object.avatarType, value.hasPrefix("preset:"),
              let index = Int(value.dropFirst(7)), (0...7).contains(index) else { return 0 }
        return index
    }
    var body: some View {
        Group {
            if let bytes = model.localAvatar(target), let image = UIImage(data: bytes) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if model.objectPreferences.presentation(for: target).avatarPreset == nil, object.avatarType == "file",
               let bytes = model.avatars[AvatarCache.key(guestID: guestID, objectID: object.id)],
               let image = UIImage(data: bytes) {
                Image(uiImage: image).resizable().scaledToFill()
            } else { Image("object-\(index + 1)").resizable().scaledToFill() }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.25))
            .overlay(RoundedRectangle(cornerRadius:size * 0.25).strokeBorder(Color(uiColor:.systemGray4),lineWidth:1))
            .accessibilityHidden(true)
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
        Group {
            if let bytes = try? object.avatar(masterKey: masterKey), let image = UIImage(data: bytes) {
                Image(uiImage: image).resizable().scaledToFill()
            } else { Image("object-\(index + 1)").resizable().scaledToFill() }
        }.frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.25))
            .overlay(RoundedRectangle(cornerRadius:size * 0.25).strokeBorder(Color(uiColor:.systemGray4),lineWidth:1))
            .accessibilityHidden(true)
    }
}
