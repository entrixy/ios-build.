import SwiftUI
import UIKit

/// Cover every app-owned presentation, including sheets, while the scene is inactive.
/// This is an app-switcher privacy cover, not a claim that iOS screenshots are disabled.
struct AppPrivacyShield: UIViewRepresentable {
    let enabled: Bool
    let covered: Bool
    func makeUIView(context: Context) -> PrivacyShieldAnchor { PrivacyShieldAnchor(frame: .zero) }
    func updateUIView(_ view: PrivacyShieldAnchor, context: Context) {
        view.enabled = enabled; view.covered = covered; view.updateShield()
    }
    static func dismantleUIView(_ view: PrivacyShieldAnchor, coordinator: ()) { view.removeShield() }
}

final class PrivacyShieldAnchor: UIView {
    var enabled = false
    var covered = false
    private var shield: UIWindow?
    override init(frame: CGRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(resigning), name: UIApplication.willResignActiveNotification, object: nil)
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    deinit { NotificationCenter.default.removeObserver(self) }
    override func didMoveToWindow() { super.didMoveToWindow(); updateShield() }
    @objc private func resigning() { covered = true; updateShield() }
    func removeShield() { shield?.isHidden = true; shield = nil }
    func updateShield() {
        guard enabled, covered, let scene = window?.windowScene else { shield?.isHidden = true; return }
        if shield?.windowScene !== scene {
            removeShield()
            let controller = UIViewController()
            controller.overrideUserInterfaceStyle = traitCollection.userInterfaceStyle
            controller.view.backgroundColor = .systemGroupedBackground
            let icon = UIImageView(image: UIImage(systemName: "lock.fill"))
            icon.tintColor = .secondaryLabel; icon.contentMode = .scaleAspectFit
            icon.translatesAutoresizingMaskIntoConstraints = false
            controller.view.addSubview(icon)
            NSLayoutConstraint.activate([
                icon.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
                icon.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 40), icon.heightAnchor.constraint(equalToConstant: 40)
            ])
            let cover = UIWindow(windowScene: scene)
            cover.windowLevel = .alert + 1
            cover.rootViewController = controller
            shield = cover
        }
        shield?.isHidden = false
    }
}
