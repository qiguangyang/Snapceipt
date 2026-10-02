import SwiftUI

struct ClientFollowUpEditorView: View {
    let store: ClientFollowUpStore
    let clientId: String
    var followUp: ClientFollowUp? = nil
    let scheduler: FollowUpNotificationScheduler
    let onSaved: (ClientFollowUp) -> Void
    let onClose: () -> Void

    @State private var title = ""
    @State private var wallTime = Date()
    @State private var timezone = TimeZone.current.identifier
    @State private var errorMessage: String?
    @State private var saving = false
    @State private var loaded = false
    private var resolution: FollowUpTime.Resolution? { try? FollowUpTime.resolve(components: components, timezone: timezone) }
    private var components: DateComponents {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c.dateComponents([.year, .month, .day, .hour, .minute], from: wallTime)
    }
    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: followUp == nil ? "Set reminder" : "Edit follow-up", onClose: onClose, titleLineLimit: 2)
            Form {
                TextField("Follow-up title", text: $title).accessibilityIdentifier(AccessibilityID.followUpTitle)
                DatePicker("Date and time", selection: $wallTime, displayedComponents: [.date, .hourAndMinute])
                    .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                    .accessibilityIdentifier(AccessibilityID.followUpTime)
                TextField("Timezone (IANA)", text: $timezone).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier(AccessibilityID.followUpTimezone)
                Text("Chosen timezone: \(timezone)")
                if let resolution {
                    Text(resolution.isAmbiguous ? "This clock time occurs twice. The first occurrence will be used (\(resolution.offsetDescription))." : resolution.offsetDescription)
                } else { Text("This clock time does not exist in the chosen timezone. Choose another time.").foregroundStyle(.red) }
                Toggle("Notify on this device", isOn: Binding(get: { scheduler.isEnabled(userId: store.userId) }, set: { enabled in
                    Task { await scheduler.setEnabled(enabled, userId: store.userId) }
                }))
                Text("Follow-ups stay in the app. This device can notify for the earliest 32 future follow-ups. Others are In-app only. A reminder never sends anything to your client.")
                if let followUp { Text(scheduler.status(for: followUp).rawValue) }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                Button(saving ? "Saving…" : "Save follow-up") { save() }.disabled(saving).accessibilityIdentifier(AccessibilityID.followUpSave)
            }
        }
        .keyboardDismissButton()
        .task {
            guard !loaded else { return }; loaded = true
            title = followUp?.title ?? ""
            timezone = followUp?.timezone ?? TimeZone.current.identifier
            let instant = followUp.map { Date(timeIntervalSince1970: Double($0.dueAt) / 1000) } ?? Date().addingTimeInterval(3600)
            var chosen = Calendar(identifier: .gregorian); chosen.timeZone = TimeZone(identifier: timezone) ?? .current
            var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
            wallTime = utc.date(from: chosen.dateComponents([.year, .month, .day, .hour, .minute], from: instant)) ?? instant
        }
    }
    private func save() {
        do {
            let resolved = try FollowUpTime.resolve(components: components, timezone: timezone)
            let saved = try store.save(id: followUp?.id, clientId: clientId, title: title,
                dueAt: Int(resolved.instant.timeIntervalSince1970 * 1000), timezone: timezone, now: Epoch.nowMs())
            saving = true; errorMessage = nil
            Task { await scheduler.refresh(); saving = false; onSaved(saved) }
        } catch { errorMessage = error.localizedDescription }
    }
}
