import SwiftUI

/// Notifications & alerts settings: APNs permission prime, Budget-alerts toggle ->
/// devices.push_enabled, Quiet hours two time pickers -> minutes + tz -> PUT /devices/me,
/// BAS-due reminder (local placeholder). Any change calls updateDevice. Uses the shared
/// settings chrome: `SheetHeader`, uppercase group labels, grouped `Card`s,
/// IconCircle-led rows with income-track toggles, and a paper-2 info note.
struct NotificationsSettingsView: View {
    let api: APIClient
    let onClose: () -> Void

    @Environment(\.accent) private var accent
    @State private var vm: NotificationsSettingsViewModel?
    @State private var quietStart = Date()
    @State private var quietEnd = Date()
    @State private var testPushMessage: String?

    var body: some View {
        ZStack {
            Palette.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                SheetHeader(title: "Notifications & alerts", onClose: onClose)
                if let vm {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            groupLabel("Alerts")
                            Card {
                                VStack(spacing: 0) {
                                    toggleRow(icon: "bell",
                                              title: "Budget alerts",
                                              subtitle: "When a budget nears its cap",
                                              isOn: Binding(
                                                get: { vm.pushEnabled },
                                                set: { on in vm.pushEnabled = on; Task { await vm.persist(); if on { await NotificationDelegate.requestAndRegister() } } }),
                                              id: AccessibilityID.notifPushToggle)
                                    rowDivider
                                    toggleRow(icon: "calendar",
                                              title: "BAS-due reminder",
                                              subtitle: "A nudge before your BAS is due",
                                              isOn: Binding(
                                                get: { vm.basReminderEnabled },
                                                set: { vm.basReminderEnabled = $0 }),
                                              id: AccessibilityID.notifBasToggle)
                                }
                            }

                            groupLabel("Quiet hours")
                            quietHoursCard(vm)

                            infoNote("Quiet hours pause push notifications during the times you choose. Critical sync alerts still arrive.")

                            #if DEBUG
                            groupLabel("Developer")
                            Card {
                                Button {
                                    Task {
                                        // Ensure the device is registered, then fire the email-in push
                                        // to this device and surface the delivery diagnostics.
                                        await NotificationDelegate.requestAndRegister()
                                        do {
                                            let r = try await api.testPush()
                                            testPushMessage = "\(r.deviceCount) device(s)\n\(r.detail)"
                                        } catch {
                                            testPushMessage = "Failed: \(error.localizedDescription)"
                                        }
                                    }
                                } label: {
                                    Text("Simulate email-in push")
                                        .font(.ui(15, .semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                }
                            }
                            infoNote("Sends the email-in push to this device. If it says “0 devices”, tap once more — the first tap registers for push.")
                            #endif
                        }
                        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 60)
                    }
                } else { Color.clear }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.notifSettingsScreen)
        .transition(.opacity)
        .alert("Test push", isPresented: Binding(get: { testPushMessage != nil },
                                                 set: { if !$0 { testPushMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(testPushMessage ?? "") }
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
            VStack(spacing: 0) {
                toggleRow(icon: "clock",
                          title: "Quiet hours",
                          subtitle: "Mute alerts overnight",
                          isOn: Binding(
                            get: { vm.quietHoursEnabled },
                            set: { vm.quietHoursEnabled = $0; Task { await vm.persist() } }),
                          id: nil)
                if vm.quietHoursEnabled {
                    rowDivider
                    DatePicker("From", selection: $quietStart, displayedComponents: .hourAndMinute)
                        .font(.ui(14.5, .semibold)).tint(accent.base)
                        .padding(.vertical, 6)
                        .accessibilityIdentifier(AccessibilityID.notifQuietStart)
                        .onChange(of: quietStart) { _, d in vm.quietStartMin = minutesOf(d); Task { await vm.persist() } }
                    rowDivider
                    DatePicker("To", selection: $quietEnd, displayedComponents: .hourAndMinute)
                        .font(.ui(14.5, .semibold)).tint(accent.base)
                        .padding(.vertical, 6)
                        .accessibilityIdentifier(AccessibilityID.notifQuietEnd)
                        .onChange(of: quietEnd) { _, d in vm.quietEndMin = minutesOf(d); Task { await vm.persist() } }
                }
            }
        }
    }

    // MARK: - Shared chrome

    private func toggleRow(icon: String, title: String, subtitle: String,
                           isOn: Binding<Bool>, id: String?) -> some View {
        HStack(spacing: 12) {
            IconCircle(name: icon, tint: accent.base, soft: accent.soft, size: 38, iconSize: 19)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                Text(subtitle).font(.ui(12, .regular)).foregroundStyle(Palette.ink3)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(Palette.income)
                .accessibilityIdentifier(id ?? "")
        }
        .padding(.vertical, 4)
    }

    private var rowDivider: some View {
        Rectangle().fill(Palette.line2).frame(height: 1).padding(.vertical, 10)
    }

    private func groupLabel(_ s: String) -> some View {
        Text(s).font(.ui(12.5, .bold)).tracking(0.3).foregroundStyle(Palette.ink3)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
    }

    private func infoNote(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Icon(name: "info", size: 16, color: Palette.ink3).padding(.top, 1)
            Text(text).font(.ui(12.5, .regular)).foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Palette.paper2, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
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
