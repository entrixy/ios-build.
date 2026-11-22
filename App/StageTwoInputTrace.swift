#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import UIKit

/// Evidence for isolated UI profiles only. Records view classes, coordinates and
/// Boolean transitions; never labels, credentials, user data or live profiles.
@MainActor enum StageTwoInputTrace {
    static func record(_ event:String,_ fields:[String:Any] = [:]) {
        guard let route = StageTwoCapture.current,route == .diagnostics || route == .networkPrivacy || route == .dataDeletion,
              let cache = FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask).first else { return }
        var row = fields
        row["event"] = event; row["route"] = route.rawValue
        row["pid"] = ProcessInfo.processInfo.processIdentifier
        row["time"] = Date().timeIntervalSince1970
        guard var data = try? JSONSerialization.data(withJSONObject:row,options:.sortedKeys) else { return }
        data.append(10)
        let file = cache.appendingPathComponent("stage-two-input.jsonl")
        if !FileManager.default.fileExists(atPath:file.path) { _ = FileManager.default.createFile(atPath:file.path,contents:nil) }
        guard let handle = try? FileHandle(forWritingTo:file) else { return }
        defer { try? handle.close() }
        do { try handle.seekToEnd(); try handle.write(contentsOf:data) } catch { }
    }
}

private final class StageTwoTouchProbe: UIGestureRecognizer {
    override func touchesBegan(_ touches:Set<UITouch>,with event:UIEvent) {
        if let touch = touches.first {
            let point = touch.location(in:touch.window)
            var classes:[String] = [],current = touch.view
            while let view = current,classes.count < 12 {
                classes.append(String(describing:type(of:view)));current = view.superview
            }
            StageTwoInputTrace.record("touch-down",["x":point.x,"y":point.y,"views":classes])
        }
        // Fail immediately: this observer neither recognises nor delays/cancels
        // a gesture and never invokes a control's action.
        state = .failed
    }
    override func canPrevent(_ preventedGestureRecognizer:UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer:UIGestureRecognizer) -> Bool { false }
}

struct StageTwoInputProbe: UIViewRepresentable {
    final class Anchor:UIView {
        private weak var observedWindow:UIWindow?
        private let probe = StageTwoTouchProbe()
        override init(frame:CGRect) {
            super.init(frame:frame)
            isUserInteractionEnabled = false;isAccessibilityElement = false
            probe.cancelsTouchesInView = false
            probe.delaysTouchesBegan = false;probe.delaysTouchesEnded = false
        }
        required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            removeProbe()
            guard let window,let route = StageTwoCapture.current,
                  route == .diagnostics || route == .networkPrivacy else { return }
            observedWindow = window;window.addGestureRecognizer(probe)
            StageTwoInputTrace.record("probe-attached")
        }
        func removeProbe() { observedWindow?.removeGestureRecognizer(probe);observedWindow = nil }
    }
    func makeUIView(context:Context) -> Anchor { Anchor(frame:.zero) }
    func updateUIView(_ view:Anchor,context:Context) { }
    static func dismantleUIView(_ view:Anchor,coordinator:()) { view.removeProbe() }
}
#endif
