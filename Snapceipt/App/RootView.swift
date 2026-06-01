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
    @Environment(AuthViewModel.self) private var authVM

    @Bindable var router: Router
    @Bindable var profiles: ProfilesStore
    @Bindable var sync: SyncEngine
    @Bindable var toasts: ToastCenter
    @Bindable var reachability: Reachability

    /// Tracks whichever Reports period was active when the user tapped Export, so
    /// the sheet inherits the selected window (spec §2.8/§6) rather than hardcoding Month.
    @State private var exportPeriod: Period = .month

    /// Biometric app-lock controller backing the Privacy screen (spec §6). Owned here
    /// for now so the Privacy toggle persists across renders within a session; the
    /// app-lock gate plan (Task 6) hoists ownership to `SnapceiptApp` + injects it via
    /// the environment and wraps the shell in the lock gate.
    @State private var appLock = AppLockController()

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
                              startMonth: profiles.activeFinancialYearStartMonth(),
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
                          startMonth: profiles.activeFinancialYearStartMonth(),
                          onClose: { router.dismissOverlay() })
                    .environment(\.accent, accent)
                    .transition(.opacity)
            }
        }
        .overlay {
            if router.overlay == .budgets {
                BudgetListView(context: profiles.context, sync: sync, userId: profiles.userId,
                               profileId: profiles.activeProfileId,
                               onClose: { router.dismissOverlay() },
                               onEdit: { router.openBudget($0) })
                    .environment(\.accent, accent).transition(.opacity)
            }
        }
        .overlay {
            if case let .budgetEditor(id) = router.overlay {
                BudgetEditorView(context: profiles.context, sync: sync, userId: profiles.userId,
                                 profileId: profiles.activeProfileId, budgetId: id,
                                 onClose: { router.dismissOverlay() })
                    .environment(\.accent, accent).transition(.opacity)
            }
        }
        .overlay {
            if router.overlay == .alerts {
                AlertsSheet(context: profiles.context, sync: sync, userId: profiles.userId,
                            profileId: profiles.activeProfileId,
                            onOpenBudget: { router.openBudget($0) },
                            onClose: { router.dismissOverlay() })
                    .environment(\.accent, accent).transition(.opacity)
            }
        }
        .overlay {
            if router.overlay == .notificationSettings {
                NotificationsSettingsView(api: captureAPI, onClose: { router.dismissOverlay() })
                    .environment(\.accent, accent).transition(.opacity)
            }
        }
        .overlay {
            if router.overlay == .loyalty {
                LoyaltyWalletView(context: profiles.context, sync: sync, userId: profiles.userId,
                                  profileId: profiles.activeProfileId,
                                  onClose: { router.dismissOverlay() },
                                  onAdd: { router.present(.loyaltyAdd) },
                                  onOpenCard: { router.present(.loyaltyCard(id: $0)) })
                    .environment(\.accent, accent).transition(.opacity)
            }
        }
        .overlay {
            if router.overlay == .loyaltyAdd {
                AddLoyaltyView(context: profiles.context, sync: sync, userId: profiles.userId,
                               profileId: profiles.activeProfileId,
                               onClose: { router.dismissOverlay() },
                               onSaved: { router.present(.loyalty) })
                    .environment(\.accent, accent).transition(.opacity)
            }
        }
        .overlay {
            if case let .loyaltyCard(id) = router.overlay {
                LoyaltyCardDetailView(context: profiles.context, cardId: id,
                                      onClose: { router.dismissOverlay() })
                    .environment(\.accent, accent).transition(.opacity)
            }
        }
        .overlay {
            if router.overlay == .quotes {
                QuoteListView(context: profiles.context, sync: sync, userId: profiles.userId,
                              profileId: profiles.activeProfileId,
                              onClose: { router.dismissOverlay() },
                              onEdit: { router.openQuote($0) })
                    .environment(\.accent, accent).transition(.opacity)
            }
        }
        .overlay {
            if case let .quoteEditor(id) = router.overlay {
                QuoteEditorView(context: profiles.context, sync: sync, api: captureAPI,
                                userId: profiles.userId, profileId: profiles.activeProfileId,
                                quoteId: id,
                                onClose: { router.dismissOverlay() })
                    .environment(\.accent, accent).transition(.opacity)
            }
        }
        .overlay {
            if router.overlay == .emailIn {
                EmailInView(context: profiles.context, sync: sync, api: captureAPI,
                            userId: profiles.userId, profileId: profiles.activeProfileId,
                            onClose: { router.dismissOverlay() },
                            onReview: { router.present(.emailInReview(id: $0)) })
                    .environment(\.accent, accent).transition(.opacity)
            }
        }
        .overlay {
            if case let .emailInReview(id) = router.overlay {
                EmailInReviewView(
                    vm: EmailInViewModel(context: profiles.context, sync: sync, api: captureAPI,
                                         userId: profiles.userId, profileId: profiles.activeProfileId),
                    transactionId: id,
                    onClose: { router.dismissOverlay() })
                    .environment(\.accent, accent).transition(.opacity)
            }
        }
        .overlay {
            if router.overlay == .tax {
                TaxSettingsView(profiles: profiles, sync: sync, onClose: { router.dismissOverlay() })
                    .environment(\.accent, accent).transition(.opacity)
            }
        }
        .overlay {
            if router.overlay == .categories {
                CategoriesView(context: profiles.context, sync: sync, userId: profiles.userId,
                               profileId: profiles.activeProfileId,
                               onEditRule: { router.present(.ruleEditor(id: $0)) },
                               onClose: { router.dismissOverlay() })
                    .environment(\.accent, accent).transition(.opacity)
            }
        }
        .overlay {
            if case let .ruleEditor(id) = router.overlay {
                RuleEditorView(context: profiles.context, sync: sync, userId: profiles.userId,
                               profileId: profiles.activeProfileId,
                               ruleId: id, onClose: { router.dismissOverlay() })
                    .environment(\.accent, accent).transition(.opacity)
            }
        }
        .overlay {
            if case let .profileDetail(id) = router.overlay {
                ProfileDetailView(profiles: profiles, sync: sync, profileId: id,
                                  onClose: { router.dismissOverlay() },
                                  onExport: { router.present(.export) })
                    .environment(\.accent, accent).transition(.opacity)
            }
        }
        .overlay {
            if router.overlay == .account {
                AccountView(api: captureAPI, auth: auth, authVM: authVM,
                            onChangeEmail: { router.present(.changeEmail) },
                            onClose: { router.dismissOverlay() })
                    .environment(\.accent, accent).transition(.opacity)
            }
        }
        .overlay {
            if router.overlay == .changeEmail {
                ChangeEmailView(api: captureAPI, auth: auth, onClose: { router.dismissOverlay() })
                    .environment(\.accent, accent).transition(.opacity)
            }
        }
        .overlay {
            if router.overlay == .privacy {
                PrivacyView(appLock: appLock, onClose: { router.dismissOverlay() })
                    .environment(\.accent, accent).transition(.opacity)
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
                startMonth: profiles.activeFinancialYearStartMonth(),
                onOpenExport: { period in exportPeriod = period; router.present(.export) },
                onOpenMileage: { router.present(.mileage) },
                onOpenWFH: { router.present(.wfh) }
            )
            .environment(\.accent, accent)
        case .profile:
            ProfileTabView(
                profiles: profiles,
                userName: auth.session?.displayName ?? "You",
                userEmail: auth.session?.email,
                onOpenNotifications: { router.present(.notificationSettings) },
                onOpenBudgets: { router.present(.budgets) },
                onOpenEmailIn: { router.present(.emailIn) },
                onOpenTax: { router.present(.tax) },
                onOpenCategories: { router.present(.categories) },
                onOpenExport: { router.present(.export) },
                onOpenPrivacy: { router.present(.privacy) },
                onOpenAccount: { router.present(.account) },
                onOpenProfileDetail: { router.present(.profileDetail(id: $0)) },
                onAddProfile: { router.present(.addProfile) },
                onSignOut: { Task { await authVM.signOut() } }
            )
            .environment(\.accent, accent)
        case .snap:
            // Never the active tab (Router routes .snap to the capture overlay),
            // but render Home as a safe fallback.
            homeStub(accent: accent)
        }
    }

    /// Home tab: profile-switcher header + alerts bell, quick actions, budget tracker.
    @ViewBuilder
    private func homeStub(accent: AccentPalette) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    ProfileSwitcherHeader(
                        store: profiles,
                        onTapSwitch: { router.go(.overlay(.profilePicker)) }
                    )
                    Button { router.present(.alerts) } label: {
                        ZStack(alignment: .topTrailing) {
                            IconCircle(name: "bell", tint: accent.base, soft: accent.soft, size: 40, iconSize: 20)
                            if unreadAlertCount > 0 {
                                Circle().fill(Palette.alert).frame(width: 10, height: 10).offset(x: 2, y: -2)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AccessibilityID.homeAlertsBell)
                }
                .padding(.horizontal, 18).padding(.top, 12)

                HStack(spacing: 12) {
                    quickAction(title: "Mileage", icon: "car", id: AccessibilityID.homeQuickMileage,
                                accent: accent) { router.present(.mileage) }
                    quickAction(title: "WFH log", icon: "wfh", id: AccessibilityID.homeQuickWFH,
                                accent: accent) { router.present(.wfh) }
                }
                .padding(.horizontal, 18).padding(.top, 14)

                HStack(spacing: 12) {
                    quickAction(title: "Loyalty Card", icon: "star", id: AccessibilityID.homeQuickLoyalty,
                                accent: accent) { router.present(.loyalty) }
                }
                .padding(.horizontal, 18).padding(.top, 12)

                // BUSINESS-ONLY: the Quotes feature is gated on the active profile type.
                if profiles.activeProfile?.type == ProfileType.business.rawValue {
                    HStack(spacing: 12) {
                        quickAction(title: "Create Quote", icon: "receipt", id: AccessibilityID.homeQuickQuote,
                                    accent: accent) { router.present(.quotes) }
                    }
                    .padding(.horizontal, 18).padding(.top, 12)
                }

                BudgetTrackerView(
                    context: profiles.context, sync: sync,
                    userId: profiles.userId, profileId: profiles.activeProfileId,
                    onEdit: { router.present(.budgets) },
                    onTapBudget: { router.openBudget($0) },
                    onAdd: { router.openBudget(nil) }
                )
                .padding(.horizontal, 18).padding(.top, 16)
            }
            // Home a11y CONTAINER: `.contain` lets `shell.home` carry this identifier
            // WITHOUT flattening the subtree (which would clobber `profile.switcher`,
            // the bell, the budget-row ids, and the quick-action ids).
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.shellHome)
            .padding(.bottom, 110)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream)
    }

    /// Unread alert count for the Home bell dot, derived from live budgets + the cache.
    private var unreadAlertCount: Int {
        let pid = profiles.activeProfileId
        let bd = FetchDescriptor<Budget>(predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil })
        let budgets = (try? profiles.context.fetch(bd)) ?? []
        let model = BudgetListViewModel(context: profiles.context, sync: sync,
                                        userId: profiles.userId, profileId: pid)
        let inputs = model.rows().map {
            AlertFeed.Input(budgetId: $0.budget.id, label: $0.budget.label, capCents: $0.budget.capCents,
                            alertThresholdPct: $0.budget.alertThresholdPct, spentCents: $0.spentCents,
                            alertSentAt: $0.budget.alertSentAt)
        }
        _ = budgets
        return AlertCache().unreadCount(AlertFeed.items(inputs: inputs, now: Date()))
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
                case .capture, .mileage, .wfh, .budgets, .budgetEditor, .alerts, .notificationSettings,
                     .loyalty, .loyaltyAdd, .loyaltyCard, .quotes, .quoteEditor,
                     .emailIn, .emailInReview,
                     .tax, .categories, .ruleEditor, .profileDetail,
                     .account, .privacy, .changeEmail:
                    return nil
                default: return router.overlay
                }
            },
            set: { newValue in
                // The full-screen overlays (presented via `.overlay`, not `.sheet`) must
                // never be dismissed-as-sheet here. `.budgetEditor` carries an associated
                // value, so it is matched separately rather than via a Set membership test.
                let fullScreen: Set<String> = [Overlay.capture.id, Overlay.mileage.id, Overlay.wfh.id,
                                               Overlay.budgets.id, Overlay.alerts.id,
                                               Overlay.notificationSettings.id,
                                               Overlay.loyalty.id, Overlay.loyaltyAdd.id,
                                               Overlay.quotes.id, Overlay.emailIn.id,
                                               Overlay.tax.id, Overlay.categories.id,
                                               Overlay.account.id, Overlay.privacy.id, Overlay.changeEmail.id]
                if newValue == nil, let cur = router.overlay,
                   !fullScreen.contains(cur.id),
                   !cur.id.hasPrefix("budgetEditor"), !cur.id.hasPrefix("loyaltyCard"),
                   !cur.id.hasPrefix("quoteEditor"), !cur.id.hasPrefix("emailInReview"),
                   !cur.id.hasPrefix("ruleEditor"), !cur.id.hasPrefix("profileDetail") {
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
        case .mileage, .wfh, .budgets, .budgetEditor, .alerts, .notificationSettings,
             .loyalty, .loyaltyAdd, .loyaltyCard, .quotes, .quoteEditor,
             .emailIn, .emailInReview,
             .tax, .categories, .ruleEditor, .profileDetail,
             .account, .privacy, .changeEmail:
            EmptyView()  // handled by the full-screen overlays (overlay blocks added in Task 5)
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
        let window = exportPeriod.window(now: now, startMonth: profiles.activeFinancialYearStartMonth())
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
