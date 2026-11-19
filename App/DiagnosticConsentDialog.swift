import SwiftUI
import UIKit

/// Native controls provide an explicit bounded accessibility tree for the consent
/// panel. The SwiftUI provider repeatedly timed out even in a separate modal host.
struct DiagnosticConsentDialog: UIViewControllerRepresentable {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var service: AppDiagnostics
    func makeUIViewController(context:Context) -> DiagnosticConsentController { DiagnosticConsentController() }
    func updateUIViewController(_ controller:DiagnosticConsentController,context:Context) {
        controller.configure(ready:service.ready && model.canManageGuestAccess,
                             error:service.message.map { ProductText.string($0) }) { service.setConsent($0) }
    }
}

private final class ConsentActionButton: UIButton {
    var pressedOpacity: CGFloat = 0.86
    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? pressedOpacity : 1 } }
}

@MainActor final class DiagnosticConsentController: UIViewController {
    private struct Presentation: Equatable {
        let ready: Bool
        let title: String
        let body: String
        let later: String
        let allow: String
        let error: String?
    }
    private var presentation: Presentation?
    private let panel = UIView()
    private let scroll = UIScrollView()
    private let labels = UIStackView()
    private let footer = UIStackView()
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let errorLabel = UILabel()
    private let later = ConsentActionButton(type:.system)
    private let allow = ConsentActionButton(type:.system)
    private var scrollHeight: NSLayoutConstraint!
    private var consent: ((Bool) -> Void)?

    override func loadView() {
        view = UIView(); view.backgroundColor = UIColor.black.withAlphaComponent(DesignMetrics.dialogDimOpacity)
        // The presented host supplies the modal AX boundary. This child only
        // supplies its explicit leaf order, not a second nested modal boundary.
        panel.backgroundColor = .secondarySystemGroupedBackground
        panel.layer.cornerRadius = DesignMetrics.dialogCorner
        panel.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(panel)
        for label in [titleLabel,bodyLabel,errorLabel] {
            label.numberOfLines = 0; label.lineBreakMode = .byWordWrapping
            label.adjustsFontForContentSizeCategory = true; label.isAccessibilityElement = true
            label.accessibilityTraits = .staticText; label.textColor = .label
        }
        let titleFont = UIFont.preferredFont(forTextStyle:.title3)
        titleLabel.font = UIFont(descriptor:titleFont.fontDescriptor.withSymbolicTraits(.traitBold) ?? titleFont.fontDescriptor,size:0)
        titleLabel.accessibilityTraits.insert(.header)
        titleLabel.accessibilityIdentifier = "diagnostic-consent-title"
        bodyLabel.font = .preferredFont(forTextStyle:.body)
        bodyLabel.accessibilityIdentifier = "diagnostic-consent-body"
        errorLabel.font = .preferredFont(forTextStyle:.footnote); errorLabel.textColor = UIColor(AppPalette.destructive)
        labels.axis = .vertical; labels.spacing = DesignMetrics.dialogGap
        [titleLabel,bodyLabel,errorLabel].forEach { labels.addArrangedSubview($0) }
        labels.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false; scroll.showsVerticalScrollIndicator = false; scroll.contentInsetAdjustmentBehavior = .never
        scroll.addSubview(labels)
        footer.axis = .horizontal; footer.spacing = DesignMetrics.dialogActionGap; footer.distribution = .fillEqually
        for button in [later,allow] {
            button.titleLabel?.font = .preferredFont(forTextStyle:.headline)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.titleLabel?.numberOfLines = 0
            button.contentEdgeInsets = UIEdgeInsets(top:12,left:14,bottom:12,right:14)
            button.layer.cornerRadius = DesignMetrics.actionRadius; button.clipsToBounds = true
            button.heightAnchor.constraint(greaterThanOrEqualToConstant:DesignMetrics.primaryHeight).isActive = true
            button.setTitleColor(UIColor(Brand.secondaryInk),for:.disabled)
            footer.addArrangedSubview(button)
        }
        later.pressedOpacity = 0.8
        later.accessibilityIdentifier = "diagnostic-consent-later"
        allow.accessibilityIdentifier = "diagnostic-consent-allow"
        later.addAction(UIAction { [weak self] _ in self?.consent?(false) },for:.touchUpInside)
        allow.addAction(UIAction { [weak self] _ in self?.consent?(true) },for:.touchUpInside)
        let stack = UIStackView(arrangedSubviews:[scroll,footer])
        stack.axis = .vertical; stack.spacing = DesignMetrics.dialogGap
        stack.translatesAutoresizingMaskIntoConstraints = false; panel.addSubview(stack)
        let preferredWidth = panel.widthAnchor.constraint(equalTo:view.safeAreaLayoutGuide.widthAnchor,constant:-2*DesignMetrics.dialogMargin)
        preferredWidth.priority = .defaultHigh
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant:1)
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo:view.safeAreaLayoutGuide.centerXAnchor),
            panel.centerYAnchor.constraint(equalTo:view.safeAreaLayoutGuide.centerYAnchor),
            panel.widthAnchor.constraint(lessThanOrEqualToConstant:DesignMetrics.dialogMaxWidth),
            panel.widthAnchor.constraint(lessThanOrEqualTo:view.safeAreaLayoutGuide.widthAnchor,constant:-2*DesignMetrics.dialogMargin),
            preferredWidth,
            stack.topAnchor.constraint(equalTo:panel.topAnchor,constant:DesignMetrics.dialogPadding),
            stack.bottomAnchor.constraint(equalTo:panel.bottomAnchor,constant:-DesignMetrics.dialogPadding),
            stack.leadingAnchor.constraint(equalTo:panel.leadingAnchor,constant:DesignMetrics.dialogPadding),
            stack.trailingAnchor.constraint(equalTo:panel.trailingAnchor,constant:-DesignMetrics.dialogPadding),
            labels.topAnchor.constraint(equalTo:scroll.contentLayoutGuide.topAnchor),
            labels.bottomAnchor.constraint(equalTo:scroll.contentLayoutGuide.bottomAnchor),
            labels.leadingAnchor.constraint(equalTo:scroll.contentLayoutGuide.leadingAnchor),
            labels.trailingAnchor.constraint(equalTo:scroll.contentLayoutGuide.trailingAnchor),
            labels.widthAnchor.constraint(equalTo:scroll.frameLayoutGuide.widthAnchor), scrollHeight,
        ])
        view.accessibilityElements = [panel]
    }
    func configure(ready:Bool,error:String?,consent:@escaping (Bool) -> Void) {
        loadViewIfNeeded(); self.consent = consent
        let next = Presentation(ready:ready,title:ProductText.string("crash_consent_title"),body:ProductText.string("crash_consent_text"),later:ProductText.string("crash_consent_later"),allow:ProductText.string("crash_consent_allow"),error:error)
        guard next != presentation else { return }; presentation = next
        titleLabel.text = next.title
        bodyLabel.text = next.body
        errorLabel.text = error; errorLabel.isHidden = error == nil
        later.setTitle(next.later,for:.normal)
        allow.setTitle(next.allow,for:.normal)
        later.isEnabled = ready; allow.isEnabled = ready
        later.backgroundColor = ready ? UIColor(AppPalette.secondary) : .systemGray5
        allow.backgroundColor = ready ? UIColor(Brand.ink) : .tertiarySystemFill
        later.setTitleColor(UIColor(Brand.ink),for:.normal); allow.setTitleColor(.systemBackground,for:.normal)
        panel.accessibilityElements = error == nil ? [titleLabel,bodyLabel,later,allow] : [titleLabel,bodyLabel,errorLabel,later,allow]
        view.setNeedsLayout()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard scroll.bounds.width > 0 else { return }
        let fitting = CGSize(width:scroll.bounds.width,height:UIView.layoutFittingCompressedSize.height)
        let textHeight = labels.systemLayoutSizeFitting(fitting,withHorizontalFittingPriority:.required,verticalFittingPriority:.fittingSizeLevel).height
        let buttonsHeight = footer.systemLayoutSizeFitting(fitting,withHorizontalFittingPriority:.required,verticalFittingPriority:.fittingSizeLevel).height
        let available = max(1,view.safeAreaLayoutGuide.layoutFrame.height-2*(DesignMetrics.dialogOuterInset+DesignMetrics.dialogPadding)-DesignMetrics.dialogGap-buttonsHeight)
        let height = min(textHeight,available)
        if abs(scrollHeight.constant-height) > 0.5 { scrollHeight.constant = height; view.setNeedsLayout() }
    }
}
