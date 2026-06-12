import SwiftUI

/// Notifications & alerts settings: APNs permission prime, Budget-alerts toggle ->
/// devices.push_enabled, Quiet hours two time pickers -> minutes + tz -> PUT /devices/me,
/// BAS-due reminder (local placeholder). Any change calls updateDevice.
struct NotificationsSettingsView: View {
    let api: APIClient
    let onClose: () -> Void

    @Environment(\.accent) private var accent
    @State private var vm: NotificationsSettingsViewModel?
    @State private var quietStart = Date()
    @State private var quietEnd = Date()

    var body: some View {
        ZStack {
            Palette.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                SheetHeader(title: "Notifications & alerts", onClose: onClose)
                if let vm {
                    ScrollView {
                        VStack(spacing: 14) {
                            Card {
                                Toggle("Budget alerts", isOn: Binding(
                                    get: { vm.pushEnabled },
                                    set: { on in vm.pushEnabled = on; Task { await vm.persist(); if on { await NotificationDelegate.requestAndRegister() } } }))
                                    .font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                                    .tint(accent.base)
                                    .accessibilityIdentifier(AccessibilityID.notifPushToggle)
                            }
                            quietHoursCard(vm)
                            Card {
                                Toggle("BAS-due reminder", isOn: Binding(
                                    get: { vm.basReminderEnabled }, set: { vm.basReminderEnabled = $0 }))
                                    .font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                                    .tint(accent.base)
                                    .accessibilityIdentifier(AccessibilityID.notifBasToggle)
                            }
                        }
                        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 60)
                    }
                } else { Color.clear }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.notifSettingsScreen)
        .transition(.opacity)
        .task {
            if vm == nil {
                let model = NotificationsSettingsViewModel(api: api)
                quietStart = dateFor(model.quietStartMin)
                quietEnd = dateFor(model.quietEndMin)
                vm = model
            }
        }
    }

    @ViewBuilder private func quietHoursCard(_ vm: NotificationsSettingsViewModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Quiet hours", isOn: Binding(
                    get: { vm.quietHoursEnabled },
                    set: { vm.quietHoursEnabled = $0; Task { await vm.persist() } }))
                    .font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                    .tint(accent.base)
                    .accessibilityIdentifier(AccessibilityID.notifQuietToggle)
                if vm.quietHoursEnabled {
                    DatePicker("From", selection: $quietStart, displayedComponents: .hourAndMinute)
                        .accessibilityIdentifier(AccessibilityID.notifQuietStart)
                        .onChange(of: quietStart) { _, d in vm.quietStartMin = minutesOf(d); Task { await vm.persist() } }
                    DatePicker("To", selection: $quietEnd, displayedComponents: .hourAndMinute)
                        .accessibilityIdentifier(AccessibilityID.notifQuietEnd)
                        .onChange(of: quietEnd) { _, d in vm.quietEndMin = minutesOf(d); Task { await vm.persist() } }
                }
            }
        }
    }

    private func minutesOf(_ d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return QuietHours.minutes(hour: c.hour ?? 0, minute: c.minute ?? 0)
    }
    private func dateFor(_ m: Int) -> Date {
        let c = QuietHours.components(fromMinutes: m)
        return Calendar.current.date(bySettingHour: c.hour, minute: c.minute, second: 0, of: Date()) ?? Date()
    }
}
