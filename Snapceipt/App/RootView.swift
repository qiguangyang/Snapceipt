import SwiftUI
import SwiftData

/// Top-level auth + first-run gate, then the authed app shell.
///
/// Composition order (foundation): Task 1 shipped the placeholder shell; Task 12
/// gated on auth + first profile; Task 14 (here) replaces the placeholder with the
/// real tab-bar shell. Routing:
/// - no session → `SignInView`
/// - magic link requested / sent / verifying → `MagicLinkWaitView`
/// - signed in but no profile → `OnboardingView`
/// - signed in with a profile → `ShellView` (TabBar + tabs + overlays + cross-cutting)
struct RootView: View {
    @Environment(AuthViewModel.self) private var authVM
    @Environment(Router.self) private var router
    @Environment(ProfilesStore.self) private var profiles
    @Environment(SyncEngine.self) private var sync
    @Environment(ToastCenter.self) private var toasts
    @Environment(Reachability.self) private var reachability

    /// Live count of non-deleted profiles drives the "needs onboarding" gate.
    @Query(filter: #Predicate<Profile> { $0.deletedAt == nil }) private var profileRows: [Profile]

    var body: some View {
        Group {
            switch authVM.state {
            case .signedIn:
                if profileRows.isEmpty {
                    OnboardingView(onFinished: {
                        // No-op: inserting the first profile flips `profileRows.isEmpty`,
                        // which re-renders this view straight into the shell.
                    })
                } else {
                    ShellView(
                        router: router,
                        profiles: profiles,
                        sync: sync,
                        toasts: toasts,
                        reachability: reachability
                    )
                }
            case .requestingLink:
                // A link request is in flight — keep the wait screen up so the UI does
                // not flash back to Sign-in between request and "link sent".
                MagicLinkWaitView()
            case .awaitingLink:
                MagicLinkWaitView()
            case .verifying where authVM.pendingEmail != nil:
                // A tapped magic link is verifying — keep the wait screen up so the UI
                // doesn't flash back to Sign-in mid-verify.
                MagicLinkWaitView()
            case .error where authVM.pendingEmail != nil:
                // An expired/invalid link after a request: show the error on the wait screen.
                MagicLinkWaitView()
            default:
                SignInView()
            }
        }
        // Animate first-run AND auth-state transitions (not only `isEmpty`), so the
        // SignIn → Wait → Onboarding → Shell handoffs cross-fade rather than snap.
        .animation(.easeInOut(duration: 0.28), value: profileRows.isEmpty)
        .animation(.easeInOut(duration: 0.28), value: authVM.state)
    }
}

/// The authed app shell: tab content + floating raised-center TabBar + overlays +
/// cross-cutting offline/sync/toast layers. Switching tab or active profile re-keys
/// the screen so the enter animation replays. `SyncEngine.sync()` fires on launch
/// and on foreground.
struct ShellView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AuthStore.self) private var auth

    @Bindable var router: Router
    @Bindable var profiles: ProfilesStore
    @Bindable var sync: SyncEngine
    @Bindable var toasts: ToastCenter
    @Bindable var reachability: Reachability

    /// Tracks whichever Reports period was active when the user tapped Export, so
    /// the sheet inherits the selected window (spec §2.8/§6) rather than hardcoding Month.
    @State private var exportPeriod: Period = .month

    var body: some View {
        let accent = profiles.accent

        ZStack(alignment: .bottom) {
            Palette.cream.ignoresSafeArea()

            // --- Active tab content, re-keyed on tab + active profile ---
            VStack(spacing: 0) {
                OfflineBanner(reachability: reachability)
                tabContent(accent: accent)
                    // Re-key: a new identity replays the enter animation.
                    .id(router.tab.rawValue + "|" + profiles.activeProfileId)
                    .transition(.opacity.combined(with: .offset(y: 10)))
                    .animation(.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.34),
                               value: router.tab)
                    .animation(.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.34),
                               value: profiles.activeProfileId)
            }

            // --- Floating sync status pill (top-trailing, hidden when idle) ---
            VStack {
                HStack {
                    Spacer()
                    SyncStatusView(status: sync.status)
                        .padding(.trailing, 18)
                        .padding(.top, 6)
                }
                Spacer()
            }

            // --- Floating raised-center tab bar ---
            // `.accessibilityElement(children: .contain)` makes this an a11y CONTAINER:
            // it carries the `shell.tabbar` identifier WITHOUT overriding the inner tab
            // buttons' own identifiers (`tab.home`, `tabbar.snap`, …). Applying
            // `.accessibilityIdentifier` directly to the composite TabBar would instead
            // propagate down and clobber every child id to `shell.tabbar`.
            TabBar(router: router, accent: accent)
                .padding(.bottom, 22)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(AccessibilityID.shellTabBar)
        }
        // Re-skin the whole shell to the active profile's accent at runtime.
        .environment(\.accent, accent)
        // --- Bottom-sheet overlays (profile picker / add-profile) ---
        // Presented natively so the sheets' own `@Environment(\.dismiss)` works and
        // the system grabber/detents render; dismissal clears the router overlay.
        .sheet(item: sheetBinding) { overlay in
            sheetContent(for: overlay)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .environment(\.accent, accent)
        }
        // --- Full-screen overlays ---
        .overlay {
            if router.overlay == .capture { captureCover(accent: accent) }
        }
        .overlay {
            if router.overlay == .mileage {
                MileageScreen(context: profiles.context, sync: sync,
                              userId: profiles.userId,
                              profileId: profiles.activeProfileId,
                              startMonth: 7,
                              onClose: { router.dismissOverlay() })
                    .environment(\.accent, accent)
                    .transition(.opacity)
            }
        }
        .overlay {
            if router.overlay == .wfh {
                WFHScreen(context: profiles.context, sync: sync,
                          userId: profiles.userId,
                          profileId: profiles.activeProfileId,
                          startMonth: 7,
                          onClose: { router.dismissOverlay() })
                    .environment(\.accent, accent)
                    .transition(.opacity)
            }
        }
        // --- Global toasts on top of everything ---
        .toastHost(toasts)
        .task {
            profiles.rescope(to: auth.session?.userId ?? "")
            await sync.sync()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await sync.sync() }
            }
        }
    }

    // MARK: - Tab content

    @ViewBuilder
    private func tabContent(accent: AccentPalette) -> some View {
        switch router.tab {
        case .home:
            homeStub(accent: accent)
        case .activity:
            StubTabView(title: "Activity", accent: accent)
        case .reports:
            ReportsView(
                context: profiles.context,
                userId: profiles.userId,
                profileId: profiles.activeProfileId,
                profileName: profiles.activeProfile?.name ?? "",
                startMonth: 7,
                onOpenExport: { period in exportPeriod = period; router.present(.export) },
                onOpenMileage: { router.present(.mileage) },
                onOpenWFH: { router.present(.wfh) }
            )
            .environment(\.accent, accent)
        case .profile:
            StubTabView(title: "Profile", accent: accent)
        case .snap:
            // Never the active tab (Router routes .snap to the capture overlay),
            // but render Home as a safe fallback.
            homeStub(accent: accent)
        }
    }

    /// Home-tab stub: the profile-switcher header (Task 13) over a placeholder body.
    @ViewBuilder
    private func homeStub(accent: AccentPalette) -> some View {
        VStack(spacing: 0) {
            ProfileSwitcherHeader(
                store: profiles,
                onTapSwitch: { router.go(.overlay(.profilePicker)) }
            )
            .padding(.horizontal, 18)
            .padding(.top, 12)

            HStack(spacing: 12) {
                quickAction(title: "Mileage", icon: "car", id: AccessibilityID.homeQuickMileage,
                            accent: accent) { router.present(.mileage) }
                quickAction(title: "WFH log", icon: "wfh", id: AccessibilityID.homeQuickWFH,
                            accent: accent) { router.present(.wfh) }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)

            Spacer()
            VStack(spacing: 12) {
                ZStack {
                    Circle().fill(accent.soft).frame(width: 96, height: 96)
                    Icon(name: "receipt", size: 34, color: accent.base)
                }
                Text("Snap a receipt")
                    .font(.display(20))
                    .foregroundStyle(Palette.ink)
                Text("Your dashboard lands in the next build.")
                    .font(.ui(13.5))
                    .foregroundStyle(Palette.ink3)
            }
            // Home marker for UI tests. Deliberately on the content body (a sibling of
            // the ProfileSwitcherHeader) — NOT the outer VStack — so it does not flatten
            // onto / shadow the header button's `profile.switcher` identifier.
            .accessibilityIdentifier(AccessibilityID.shellHome)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream)
    }

    /// One Home quick-action tile -> opens a logbook overlay.
    @ViewBuilder
    private func quickAction(title: String, icon: String, id: String,
                             accent: AccentPalette, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconCircle(name: icon, tint: accent.base, soft: accent.soft, size: 38, iconSize: 19)
                Text(title).font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.line2, lineWidth: 1))
            .cardShadow()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    // MARK: - Overlays

    /// The bottom-sheet overlays (`profilePicker` / `addProfile`) routed through
    /// `.sheet(item:)`. The capture cover is handled separately (full-screen overlay),
    /// so it is excluded here. Clearing the binding (swipe-down) clears the router.
    private var sheetBinding: Binding<Overlay?> {
        Binding(
            get: {
                switch router.overlay {
                case .capture, .mileage, .wfh: return nil
                default: return router.overlay
                }
            },
            set: { newValue in
                let fullScreen: Set<Overlay> = [.capture, .mileage, .wfh]
                if newValue == nil, let cur = router.overlay, !fullScreen.contains(cur) {
                    router.dismissOverlay()
                } else if let newValue {
                    router.overlay = newValue
                }
            }
        )
    }

    @ViewBuilder
    private func sheetContent(for overlay: Overlay) -> some View {
        switch overlay {
        case .profilePicker:
            ProfilePickerSheet(
                store: profiles,
                onAddProfile: { router.go(.overlay(.addProfile)) }
            )
            .frame(maxHeight: .infinity, alignment: .bottom)
            .background(Palette.cream)
        case .addProfile:
            AddProfileView(vm: makeAddProfileVM())
        case .export:
            ExportSheet(
                api: captureAPI,   // reuse the shell's existing live/stub APIClient (no duplicate property)
                profileId: profiles.activeProfileId,
                profileName: profiles.activeProfile?.name ?? "",
                from: exportWindow.from,
                to: exportWindow.to,
                periodLabel: exportWindow.label,
                receiptsCount: exportWindow.receiptsCount,
                deductibleCents: exportWindow.deductibleCents,
                savedAccountantEmail: exportWindow.savedAccountantEmail,
                onSaveAccountantEmail: { saveAccountantEmail($0) },
                onClose: { router.dismissOverlay() }
            )
            .frame(maxHeight: .infinity, alignment: .bottom)
            .background(Palette.cream)
        case .capture:
            EmptyView()  // handled by the full-screen capture overlay
        case .mileage, .wfh:
            EmptyView()  // handled by the full-screen overlays
        }
    }

    /// Build a fresh AddProfile view-model wired to the shell's store/context/user.
    private func makeAddProfileVM() -> AddProfileViewModel {
        AddProfileViewModel(
            store: profiles,
            context: profiles.context,
            userId: profiles.userId
        )
    }

    /// The full-screen capture flow, presented when the Snap tab routes to `.capture`.
    /// Under `-uiTestStub` it starts at the Scan stage with a canned image (no camera).
    @ViewBuilder
    private func captureCover(accent: AccentPalette) -> some View {
        CaptureHost(
            api: captureAPI,
            sync: sync,
            profiles: profiles,
            reachability: reachability,
            context: profiles.context,
            userId: profiles.userId,
            stub: captureStub,
            onClose: { router.dismissOverlay() }
        )
        .environment(\.accent, accent)
        .transition(.opacity)
    }

    /// The APIClient the capture flow calls. Reuses the app's live/stub client built at
    /// launch via `AppLaunch` (DEBUG) and falls back to the live client in Release.
    private var captureAPI: APIClient {
        #if DEBUG
        return AppLaunch.current.makeAPIClient(auth: auth)
        #else
        return LiveAPIClient(baseURL: URL(string: "https://api.snapceipt.app")!, auth: auth)
        #endif
    }

    /// The export range + detail-card values for the currently-selected Reports period,
    /// scoped to the active profile. `exportPeriod` is set when the user taps Export in
    /// ReportsView, so this window reflects whichever period was active (spec §2.8/§6).
    /// Receipts count = transactions in range; locally we show the in-range txn count.
    private var exportWindow: (from: String, to: String, label: String,
                               receiptsCount: Int, deductibleCents: Int,
                               savedAccountantEmail: String?) {
        let now = Date()
        let window = exportPeriod.window(now: now, startMonth: 7)
        let iso = ExportDateFormatter.shared
        let pid = profiles.activeProfileId
        let td = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil })
        let rows = (try? profiles.context.fetch(td)) ?? []
        let snaps = rows.map {
            TransactionQuery.Txn(txnDate: $0.txnDate, amountCents: $0.amountCents,
                                 catKey: $0.catKey, deductiblePct: $0.deductiblePct, gstCents: $0.gstCents)
        }
        let inRange = rows.filter { iso.date(from: $0.txnDate).map { $0 >= window.start && $0 < window.end } ?? false }
        // "Deductible total" for the export DETAIL card = the per-transaction deductible
        // over the SELECTED period only — NOT the FY-to-date pill. We reuse
        // `deductibleYTD` by passing the selected-period window as `fyWindow:` with EMPTY
        // logbook claims, so it reduces to Σ round(−amount × pct/100) over in-window txns. (spec §6)
        let deductible = TransactionQuery.deductibleYTD(snaps, fyWindow: window,
                                                        vehicleYearClaims: [], wfhClaims: [])
        var sd = FetchDescriptor<TaxSettings>(predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil })
        sd.fetchLimit = 1
        let saved = (try? profiles.context.fetch(sd))?.first?.accountantEmail
        return (iso.string(from: window.start), iso.string(from: window.end.addingTimeInterval(-86_400)),
                window.label, inRange.count, deductible, saved)
    }

    /// Persist the accountant email on the active profile's TaxSettings + enqueue sync.
    /// Mirrors `TaxSettingsSeeder.ensure`'s fetch-then-branch (no `modelContext` probing).
    private func saveAccountantEmail(_ email: String) {
        let pid = profiles.activeProfileId
        var sd = FetchDescriptor<TaxSettings>(predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil })
        sd.fetchLimit = 1
        let row: TaxSettings
        if let existing = (try? profiles.context.fetch(sd))?.first {
            row = existing
        } else {
            row = TaxSettings(userId: profiles.userId, profileId: pid)
            profiles.context.insert(row)
        }
        row.accountantEmail = email
        row.updatedAt = Epoch.nowMs()
        try? profiles.context.save()
        sync.enqueue(op: "upsert", entityType: .taxSettings, entity: row)
    }

    /// The canned (image, rawText) used by the camera-less UI test, or nil in production.
    private var captureStub: (image: UIImage, rawText: String)? {
        #if DEBUG
        return AppLaunch.current.cannedScan
        #else
        return nil
        #endif
    }
}

/// Shared "yyyy-MM-dd" UTC formatter for export range parsing/formatting.
enum ExportDateFormatter {
    static let shared: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

#if DEBUG
#Preview {
    let container = makeSnapceiptContainer(inMemory: true)
    let context = ModelContext(container)
    let auth = AuthStore(keychain: Keychain(service: "sc.preview"))
    let toast = ToastCenter()
    let engine = SyncEngine(api: PreviewAPIClient(), context: context, auth: auth, toast: toast)
    let store = ProfilesStore(context: context, sync: engine, userId: "u1")
    return RootView()
        .environment(AuthViewModel(api: PreviewAPIClient(), auth: auth))
        .environment(auth)
        .environment(Router())
        .environment(store)
        .environment(engine)
        .environment(toast)
        .environment(Reachability())
        .modelContainer(container)
}
#endif
