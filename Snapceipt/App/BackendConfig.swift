import Foundation

/// Resolves which backend the app talks to, baked in at build time.
///
/// `Info.plist` carries `SNAPCEIPT_API_HOST = $(SNAPCEIPT_API_HOST)`, set per build
/// configuration (empty in Debug/Release → prod; the staging worker in the Staging
/// config). Reading it at runtime — in EVERY config, not just the DEBUG process-env seam —
/// means a Staging build always points at staging no matter how it's launched (home-screen
/// tap, TestFlight, or `devicectl`). DEBUG builds can still override via the `API_BASE_URL`
/// process-environment variable (UI tests / quick local redirects), which takes precedence.
enum BackendConfig {
    /// The production API.
    static let prodBaseURL = URL(string: "https://api.snapceipt.cc")!

    /// The base URL baked into this build via `SNAPCEIPT_API_HOST`, or prod when unset.
    static var configuredBaseURL: URL {
        if let host = Bundle.main.object(forInfoDictionaryKey: "SNAPCEIPT_API_HOST") as? String,
           !host.trimmingCharacters(in: .whitespaces).isEmpty,
           let url = URL(string: "https://\(host)") {
            return url
        }
        return prodBaseURL
    }
}
