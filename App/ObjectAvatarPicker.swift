import SwiftUI
import PhotosUI
import ImageIO
import EntrixyCore

struct ObjectAvatarPicker: View {
    @EnvironmentObject private var model: AppModel
    private func dismiss() { model.objectAvatarTarget = nil }
    let target: ObjectReference
    @State private var photo: PhotosPickerItem?
    @State private var saving = false
    @State private var message: String?
    var body: some View {
        AppDialogSurface {
            VStack(alignment: .leading, spacing: 20) {
                Text(ProductText.string("avatar_picker_title")).font(.title3.bold()).accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 14) {
                    ForEach(0..<8) { index in
                        Button { Task { await save(preset: index, jpeg: nil) } } label: {
                            Image("object-\(index + 1)").resizable().scaledToFit()
                                .frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(model.avatarPreset(target) == index ? AppPalette.selected : .clear, lineWidth: 3))
                        }.buttonStyle(.plain).accessibilityLabel(ProductText.string("ios_icon_number_fmt",index + 1))
                            .accessibilityAddTraits(model.avatarPreset(target) == index ? .isSelected : [])
                    }
                }.disabled(saving || model.ownerBusy)
                if saving { ProgressView().frame(maxWidth: .infinity) }
                if let message { Text(ProductText.systemMessage(message)).foregroundStyle(.red) }

            }
            .onChange(of: photo) { value in
                    guard let value else { return }
                    Task {
                        saving = true; defer { saving = false }
                        do {
                            guard let bytes = try await value.loadTransferable(type: Data.self) else { throw GuestCrypto.Failure.invalidEnvelope }
                            let jpeg = try ObjectAvatarImage.jpeg(bytes)
                            if await model.saveObjectAvatar(target, preset: nil, jpeg: jpeg) { dismiss() }
                            else { message = model.errorMessage ?? ProductText.string("action_no_image") }
                        } catch { message = ProductText.string("action_no_image") }
                    }
                }
        } footer: {
                EqualActionRow {
                    Button(ProductText.string("btn_cancel")) { dismiss() }.buttonStyle(SecondaryActionStyle()).disabled(saving).accessibilityIdentifier("avatar-cancel")
                    PhotosPicker(selection: $photo, matching: .images) {
                        Text(ProductText.string("avatar_picker_custom"))
                    }.buttonStyle(PrimaryActionStyle()).disabled(saving || model.ownerBusy).accessibilityIdentifier("avatar-upload")
                }
        }
    }
    private func save(preset: Int?, jpeg: Data?) async {
        saving = true; defer { saving = false }
        if await model.saveObjectAvatar(target, preset: preset, jpeg: jpeg) { dismiss() }
        else { message = model.errorMessage ?? ProductText.string("action_no_image") }
    }
}

enum ObjectAvatarImage {
    static func jpeg(_ bytes: Data) throws -> Data {
        guard bytes.count <= 40 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1024
              ] as CFDictionary) else { throw GuestCrypto.Failure.invalidEnvelope }
        let width = CGFloat(image.width), height = CGFloat(image.height), side = min(width, height)
        guard side > 0 else { throw GuestCrypto.Failure.invalidEnvelope }
        let size = min(256, side)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let result = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            UIImage(cgImage: image).draw(in: CGRect(x: -(width-side)/2 * size/side, y: -(height-side)/2 * size/side,
                width: width*size/side, height: height*size/side))
        }
        guard let jpeg = result.jpegData(compressionQuality: 0.92), AvatarCache.isImage(jpeg) else { throw GuestCrypto.Failure.invalidEnvelope }
        return jpeg
    }
}
