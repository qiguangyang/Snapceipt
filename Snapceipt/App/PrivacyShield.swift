import UIKit
import SwiftUI

/// Window-level privacy shield for the app-switcher snapshot.
///
/// RootView also shows a `PrivacyCoverView` overlay, but a SwiftUI `.overlay` lives
/// inside the root hosting controller and therefore renders BENEATH anything presented
/// modally (sheets / fullScreenCovers — receipt image viewer, export, BAS history,
/// invoice/quote editors). Those would leak into the switcher thumbnail when the app is
/// backgrounded with one open. This shield raises an opaque cover in its OWN top-level
/// `UIWindow`, which sits above every presented controller, closing that gap.
///
/// Keyed to `willResignActive` / `didBecomeActive` (the same foreground/background
/// transition as scenePhase), so the cover is up before iOS captures the snapshot and is
/// always torn down on return — `didBecomeActive` fires reliably, so the cover can't get
/// stuck.
@MainActor
final class PrivacyShield {
    static let shared = PrivacyShield()
    private var window: UIWindow?
    private var installed = false
    private init() {}

    /// Begin observing foreground/background transitions. Idempotent.
    func install() {
        guard !installed else { return }
        installed = true
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(cover),
                       name: UIApplication.willResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(uncover),
                       name: UIApplication.didBecomeActiveNotification, object: nil)
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
