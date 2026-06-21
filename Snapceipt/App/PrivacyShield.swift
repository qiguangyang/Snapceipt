import UIKit
import SwiftUI

/// Window-level privacy shield for the app-switcher snapshot.
///
/// Raises an opaque cover in its OWN top-level `UIWindow` (above every presented
/// controller, so sheets / fullScreenCovers are covered too) only when the app actually
/// enters the BACKGROUND, and removes it on return to the foreground.
///
/// Keyed to `didEnterBackground` / `willEnterForeground` — NOT `willResignActive`. iOS
/// takes the app-switcher snapshot shortly AFTER `didEnterBackground` returns, so covering
/// there still protects the snapshot. Crucially, in-app system UI (Sign in with Apple, the
/// photo picker, Files importer, share sheet) only fires `willResignActive` — never
/// `didEnterBackground` — so the cover no longer flashes behind those sheets. (Control
/// Center / notification pulldown are also `willResignActive`-only and intentionally not
/// covered.)
@MainActor
final class PrivacyShield {
    static let shared = PrivacyShield()
    private var window: UIWindow?
    private var installed = false
    private init() {}

    /// Begin observing background/foreground transitions. Idempotent.
    func install() {
        guard !installed else { return }
        installed = true
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(cover),
                       name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(uncover),
                       name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    @objc private func cover() {
        guard window == nil else { return }
        // Prefer a foreground-active/inactive scene; fall back to any window scene.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState != .background }) ?? scenes.first
        else { return }
        let host = UIHostingController(rootView: PrivacyCoverView())
        host.view.backgroundColor = UIColor(Palette.cream)   // opaque, never see-through
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        w.rootViewController = host
        w.isHidden = false
        window = w
    }

    @objc private func uncover() {
        window?.isHidden = true
        window = nil
    }
}
