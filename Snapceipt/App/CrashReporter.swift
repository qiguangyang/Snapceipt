import Foundation
import MetricKit
import UIKit

/// Lightweight MetricKit subscriber: forwards MXCrashDiagnostic / MXHangDiagnostic
/// to POST /crash-reports (best-effort). MetricKit delivers diagnostics on the next
/// launch after the event, batched into MXDiagnosticPayload; we POST each one scoped
/// to the session (the route derives userId+deviceId from the bearer). No entitlement
/// or Info.plist key is required. dSYMs: App Store Connect symbolicates server-side
/// from the uploaded archive; these envelopes carry the raw (unsymbolicated) dictionary
/// for cross-referencing — keep the dSYMs from each archive (Organizer → Download dSYMs)
/// so traces remain symbolicatable.
final class CrashReporter: NSObject, MXMetricManagerSubscriber {
    private let api: APIClient

    init(api: APIClient) {
        self.api = api
        super.init()
        MXMetricManager.shared.add(self)
    }

    deinit { MXMetricManager.shared.remove(self) }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let osVersion = "iOS " + UIDevice.current.systemVersion
        let model = Self.hardwareModel()
        for payload in payloads {
            let occurredAt = Int(payload.timeStampEnd.timeIntervalSince1970 * 1000)
            for crash in payload.crashDiagnostics ?? [] {
                post(kind: "crash", dict: crash.dictionaryRepresentation(),
                     appVersion: appVersion, osVersion: osVersion, model: model, occurredAt: occurredAt)
            }
            for hang in payload.hangDiagnostics ?? [] {
                post(kind: "hang", dict: hang.dictionaryRepresentation(),
                     appVersion: appVersion, osVersion: osVersion, model: model, occurredAt: occurredAt)
            }
        }
    }

    private func post(kind: String, dict: [AnyHashable: Any],
                      appVersion: String, osVersion: String, model: String, occurredAt: Int) {
        let payload = Dictionary(uniqueKeysWithValues:
            dict.compactMap { k, v in (k as? String).map { ($0, AnyCodable(v)) } })
        let body = DiagnosticReportBody(
            kind: kind, appVersion: appVersion, osVersion: osVersion,
            deviceModel: model, occurredAt: occurredAt, payload: payload)
        Task { try? await api.reportDiagnostic(body) }
    }

    private static func hardwareModel() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafeBytes(of: &sysinfo.machine) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }
}
