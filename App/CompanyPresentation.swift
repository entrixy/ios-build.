import SwiftUI
import ImageIO
import EntrixyCore

struct CompanyAvatar: View {
    let company: KnownCompany
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius:13).fill(AppPalette.secondary)
            if let image { Image(uiImage:image).resizable().scaledToFill() }
            else { Text(String(company.name.prefix(1)).uppercased()).font(.title2.bold()).foregroundStyle(Brand.ink) }
        }.frame(width:44,height:44).clipShape(RoundedRectangle(cornerRadius:13)).accessibilityHidden(true)
            .task(id:company.id + (company.logo ?? "") + String(company.proven)) {
                image = nil
                guard company.proven, let logo = company.logo, !logo.isEmpty,
                      let url = URL(string:"https://\(company.server)\(logo)") else { return }
                image = await CompanyLogoLoader.image(url)
            }
    }
}
enum CompanyLogoLoader {
    static func image(_ url: URL) async -> UIImage? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForResource = 15; configuration.urlCache = nil
        let boundary = ServerHTTPSession(configuration:configuration)
        defer { boundary.invalidate() }
        do {
            let session = try boundary.session(for:url)
            let (bytes,response) = try await session.bytes(from:url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            var data = Data()
            for try await byte in bytes {
                if Task.isCancelled || data.count >= 2_097_152 { return nil }; data.append(byte)
            }
            guard let source = CGImageSourceCreateWithData(data as CFData,nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:256,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else { return nil }
            return UIImage(cgImage:thumbnail)
        } catch { return nil }
    }
}

struct CompanyGrantSummary: View {
    let company: KnownCompany
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack(spacing:12) {
                CompanyAvatar(company:company)
                VStack(alignment:.leading,spacing:5) {
                    Text(company.name).font(.headline)
                    Text(company.domain ?? ProductText.string("org_domain_none")).font(.subheadline).foregroundStyle(company.proven ? Brand.ink : AppPalette.destructive)
                }
            }
            Text(ProductText.string("guests_org_note")).font(.footnote).foregroundStyle(Brand.secondaryInk)
            Text(ProductText.string(company.domain?.isEmpty == false ? "guests_org_domain_check_short" : "guests_org_domain_warn")).font(.footnote).foregroundStyle(Brand.secondaryInk)
        }.padding(.vertical,8)
    }
}

struct CompanyRequestDialog: View {
    @EnvironmentObject private var model: AppModel
    let company: KnownCompany
    let action: (_ hasGrant: Bool,_ hasObjects: Bool) -> Void
    private var granted: Bool { !model.companyKeys(company).isEmpty }
    private var hasObjects: Bool { model.owners.first(where:{ $0.server == company.server })?.objects?.contains(where:{ $0.kind == "call" && $0.numberID != nil && $0.pending == nil && $0.available != false }) == true }
    var body: some View {
        AppDialogSurface {
            VStack(alignment:.leading,spacing:18) {
                Text(ProductText.string(granted ? "org_ask_granted_title" : "org_ask_title")).font(.title3.bold())
                HStack(spacing:12) {
                    CompanyAvatar(company:company)
                    VStack(alignment:.leading,spacing:5) {
                        Text(company.name).font(.headline)
                        if let domain = company.domain, let url = URL(string:"https://" + domain) {
                            Link(destination:url) { Label(domain,systemImage:"arrow.up.right.square").font(.subheadline).foregroundStyle(company.proven ? Brand.ink : AppPalette.destructive) }
                        } else { Text(ProductText.string("org_domain_none")).font(.subheadline).foregroundStyle(Brand.secondaryInk) }
                    }
                }
                Text(ProductText.string(granted ? "org_ask_granted_body" : (hasObjects ? "org_ask_body" : "org_ask_no_objects")))

            }
        } footer: {
                HStack(spacing:12) {
                    Button(ProductText.string("org_ask_later")) { model.companyRequestID = nil }.buttonStyle(SecondaryActionStyle())
                    Button(ProductText.string(granted ? "org_ask_open_list" : (hasObjects ? "org_ask_grant" : "org_ask_add_object"))) { action(granted,hasObjects) }.buttonStyle(PrimaryActionStyle())
                }
        }
    }
}
