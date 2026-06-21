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
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AuthViewModel.self) private var authVM
    @Environment(AuthStore.self) private var auth
    @Environment(Router.self) private var router
    @Environment(ProfilesStore.self) private var profiles
    @Environment(SyncEngine.self) private var sync
    @Environment(ToastCenter.self) private var toasts
    @Environment(Reachability.self) private var reachability
    /// Shared biometric app-lock controller, injected from `SnapceiptApp` (spec §6).
    /// The `.signedIn` shell is wrapped behind a `LockScreen` gated on `isLocked`.
    @Environment(AppLockController.self) private var appLock

    /// All non-deleted profiles (any user). The `@Query` keeps the gate reactive — it
    /// re-fires when a profile is inserted — but the gate itself must scope to the
    /// CURRENT user via `currentUserHasProfile`, never this global list.
    @Query(filter: #Predicate<Profile> { $0.deletedAt == nil }) private var profileRows: [Profile]

    /// True when the SIGNED-IN user owns at least one non-deleted profile. Scoped to the
    /// user (not the global `profileRows`) so a leftover profile from a prior account or
    /// environment in the local store can't suppress onboarding for a new account — which
    /// would drop them into the shell with no active profile.
    private var currentUserHasProfile: Bool {
        let uid = auth.session?.userId ?? ""
        return !uid.isEmpty && profileRows.contains { $0.userId == uid }
    }

    /// Observe the first-run completion flag so RootView re-renders into the shell the
    /// instant the notifications step calls `OnboardingGate.markComplete()`. Without this
    /// the gate's UserDefaults read isn't reactive and the shell never appears.
    @AppStorage(OnboardingGate.key) private var onboardingComplete = false

    var body: some View {
        Group {
            switch authVM.state {
            case .signedIn:
                // Gate the shell behind onboarding AND the CURRENT user owning a profile:
                // a first-run user, a new account on a device with another account's data,
                // or one whose profiles were all deleted, is guided to create one first.
                if !onboardingComplete || !currentUserHasProfile {
                    OnboardingView(onFinished: {
                        // No-op: OnboardingGate.markComplete() (set on the notifications step)
                        // flips needsOnboarding to false, re-rendering this view into the shell.
                    })
                } else {
                    // Gate the authed shell behind the biometric lock (spec §6): lock on
                    // cold launch and on background→active; the LockScreen covers the shell
                    // until `appLock.unlock()` clears `isLocked`. Under -uiTestStub the
                    // controller's canEvaluate is false + isEnabled defaults false, so the
                    // gate never blocks seeded UI-test launches.
                    ZStack {
                        ShellView(
                            router: router,
                            profiles: profiles,
                            sync: sync,
                            toasts: toasts,
                            reachability: reachability
                        )
                        if appLock.isLocked {
                            LockScreen(onUnlock: { Task { await appLock.unlock() } })
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: appLock.isLocked)
                    .task { appLock.lockIfEnabled() }                 // cold launch
                    .onChange(of: scenePhase) { _, phase in
                        // Require an unlock when returning from background.
                        if phase == .background { appLock.lockIfEnabled() }
                    }
                }
            case .requestingLink, .awaitingLink, .awaitingOTP:
                // A link request is in flight OR sent — render the wait screen from ONE
                // switch branch so it keeps a single structural identity across the
                // `.requestingLink → .awaitingLink` round-trip a resend drives. Splitting
                // these into separate @ViewBuilder cases would destroy + recreate the view
                // mid-resend, wiping any transient confirmation state. (The spinner derives
                // from `vm.state`; the "Link sent" flash derives from `vm.linkSentCount`,
                // which lives on the VM and survives regardless.) `.awaitingOTP` is also
                // matched here so the OTP entry sheet (presented from MagicLinkWaitView)
                // survives the `.requestingLink → .awaitingOTP` state transition that
                // requestOTP drives on appear — without this the sheet's host would
                // fall through to SignInView and tear down the presentation.
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
        // `profileRows.count` is the animation driver: it re-invalidates this view when a
        // profile is inserted mid-flow, letting needsOnboarding() re-evaluate after markComplete().
        .animation(.easeInOut(duration: 0.28), value: profileRows.count)
        .animation(.easeInOut(duration: 0.28), value: authVM.state)
        // Privacy cover for the app-switcher snapshot: iOS captures the switcher
        // thumbnail at `.inactive` (before `.background`), so cover ANY non-active phase
        // with an opaque screen to keep financial content (amounts, BAS, receipts) out of
        // the snapshot. Independent of the optional Face ID lock, which gates re-entry but
        // does NOT prevent the inactive-phase snapshot on its own. (Cover only — we
        // deliberately don't engage the lock on `.inactive` to avoid forcing a re-auth
        // every time the photo picker / Files importer / share sheet briefly deactivates
        // the scene during capture.)
        .overlay {
            if scenePhase != .active {
                PrivacyCoverView()
            }
        }
        // Recover from an unrecoverable auth failure: when a refresh fails (expired/revoked
        // refresh token, account deleted elsewhere, signing-key rotation), the APIClient
        // clears the session underneath us. authVM.state isn't otherwise re-synced, so the
        // app would sit on a signed-in shell that 401s every call and shows a permanent
        // "Offline". Bounce to sign-in instead. Guarded to the signed-in case so it never
        // clobbers the transient sign-in flow states (.awaitingLink/.verifying have a nil
        // session by design).
        .onChange(of: auth.session == nil) { _, isCleared in
            if isCleared { authVM.handleSessionInvalidated() }
        }
    }
}

/// Opaque cream cover shown whenever the scene isn't active, so the app-switcher
/// snapshot never reveals financial content. Just the brand mark on the app's
/// background — no data. Used both by RootView's overlay (covers the shell) and by
/// `PrivacyShield`'s window (covers presented sheets/fullScreenCovers too).
struct PrivacyCoverView: View {
    var body: some View {
        ZStack {
            Palette.cream
            Text("Snapceipt")
                .font(.display(28, .bold))
                .foregroundStyle(Palette.ink)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
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
    /// The shared app-lock controller, injected from `SnapceiptApp`. The Privacy
    /// toggle writes `isEnabled` here; `RootView` reads `isLocked` to gate the shell.
    @Environment(AppLockController.self) private var appLock

    @Bindable var router: Router
    @Bindable var profiles: ProfilesStore
    @Bindable var sync: SyncEngine
    @Bindable var toasts: ToastCenter
    @Bindable var reachability: Reachability

    /// Hides the floating tab bar while the keyboard is showing (it otherwise floats over
    /// the keyboard during text entry, e.g. the Activity search).
    @State private var keyboard = KeyboardObserver()

    /// Tracks whichever Reports period was active when the user tapped Export, so
    /// the sheet inherits the selected window (spec §2.8/§6) rather than hardcoding Month.
    @State private var exportPeriod: Period = .month
    /// When set, the next `.export` sheet renders as the BAS-pinned pack (spec §4.7).
    @State private var basExportPinned = false
    /// Bumped whenever a full-screen overlay closes, so the Activity tab re-fetches.
    /// The tab is only re-keyed on tab/profile change (not on overlay dismiss), so a
    /// receipt deleted/edited/added from an overlay wouldn't otherwise disappear/update.
    @State private var activityReloadToken = 0

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

            // --- Floating sync status pill (top-center, hidden when idle) ---
            // Top-center is empty on all four tab headers; top-trailing covered
            // the Home alerts bell / Reports export pill. Hit-test-inert so it
            // can never swallow taps meant for the header underneath.
            VStack {
                SyncStatusView(status: sync.status)
                    .padding(.top, 6)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)

            // --- Bottom fade scrim (design's gradient behind the tab bar) ---
            // Scrolling content fades to cream under/around the floating bar, and the
            // gap beneath the pill fills with cream — so nothing bleeds through below it.
            LinearGradient(colors: [Palette.cream.opacity(0), Palette.cream],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 150)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)

            // --- Floating raised-center tab bar ---
            // `.accessibilityElement(children: .contain)` makes this an a11y CONTAINER:
            // it carries the `shell.tabbar` identifier WITHOUT overriding the inner tab
            // buttons' own identifiers (`tab.home`, `tabbar.snap`, …). Applying
            // `.accessibilityIdentifier` directly to the composite TabBar would instead
            // propagate down and clobber every child id to `shell.tabbar`.
            TabBar(router: router, accent: accent)
                // Pull the floating bar down into the bottom inset so it hugs the bottom
                // edge; the remaining margin above the home indicator keeps it clear of
                // the gesture zone.
                .padding(.bottom, -8)
                .ignoresSafeArea(.keyboard, edges: .bottom)
                // Hide the floating bar while the keyboard is up — a bottom-aligned floating
                // bar otherwise rides the keyboard up and floats over it (you don't switch
                // tabs mid-typing). Fades back in on dismissal.
                .opacity(keyboard.isVisible ? 0 : 1)
                .allowsHitTesting(!keyboard.isVisible)
                .animation(.easeInOut(duration: 0.2), value: keyboard.isVisible)
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
            if case let .manual(editId) = router.overlay {
                AddManualView(context: profiles.context, sync: sync, userId: profiles.userId,
                              profileId: profiles.activeProfileId,
                              isBusiness: profiles.activeProfile?.type == ProfileType.business.rawValue,
                              editId: editId,
                              onClose: { router.dismissOverlay(); activityReloadToken += 1 })
                    .environment(\.accent, accent).transition(.opacity)
            }
        }
        .overlay {
            // Receipt detail is a full-screen page (matches the design's TxnDetail,
            // inset:0). Presenting it as a `.sheet` from a deeply-nested Activity row
            // didn't reliably fire, so it lives here like the other detail screens.
            if case let .receiptDetail(id) = router.overlay {
                ReceiptDetailView(context: profiles.context, sync: sync, api: captureAPI, transactionId: id,
                                  onEdit: { router.present(.manual(editId: $0)) },
                                  onClose: { router.dismissOverlay(); activityReloadToken += 1 })
                    .environment(\.accent, accent).transition(.opacity)
            }
        }
        .overlay {
            if router.overlay == .budgets {
                BudgetListView(context: profiles.context, sync: sync, userId: profiles.userId,
                               profileId: profiles.activeProfileId,
                               onClose: { router.dismissOverlay(); activityReloadToken += 1 },
                               onEdit: { router.openBudget($0) })
                    .environment(\.accent, accent).transition(.opacity)
            }
        }
        .overlay {
            if case let .budgetEditor(id) = router.overlay {
                BudgetEditorView(context: profiles.context, sync: sync, userId: profiles.userId,
                                 profileId: profiles.activeProfileId, budgetId: id,
                                 onClose: { router.dismissOverlay(); activityReloadToken += 1 })
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
            if router.overlay == .invoices {
                InvoiceListView(context: profiles.context, sync: sync, userId: profiles.userId,
                                profileId: profiles.activeProfileId,
                                onClose: { router.dismissOverlay() },
                                onEdit: { router.openInvoice($0) })
                    .environment(\.accent, accent).transition(.opacity)
            }
        }
        .overlay {
            if case let .invoiceEditor(id) = router.overlay {
                InvoiceEditorView(context: profiles.context, sync: sync, api: captureAPI,
                                  userId: profiles.userId, profileId: profiles.activeProfileId,
                                  invoiceId: id,
                                  onClose: { router.dismissOverlay() })
                    .environment(\.accent, accent).transition(.opacity)
            }
        }
        .overlay {
            if router.overlay == .bas {
                BasView(context: profiles.context, api: captureAPI, userId: profiles.userId,
                        profileId: profiles.activeProfileId,
                        profileName: profiles.activeProfile?.name ?? "",
                        gstRegistered: profiles.activeProfile?.gstRegistered ?? false,
                        basPeriod: basPeriodForActive,
                        startMonth: profiles.activeFinancialYearStartMonth(),
                        onOpenExport: { basExportPinned = true; router.present(.export) },
                        onClose: { router.dismissOverlay() })
                    .environment(\.accent, accent).transition(.opacity)
            }
        }
        .overlay {
            if case let .quoteEditor(id) = router.overlay {
                QuoteEditorView(context: profiles.context, sync: sync, api: captureAPI,
                                userId: profiles.userId, profileId: profiles.activeProfileId,
                                quoteId: id,
                                onClose: { router.dismissOverlay() },
                                onConvert: { invId in router.openInvoice(invId) })
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
                TaxSettingsView(profiles: profiles, sync: sync, api: captureAPI, onClose: { router.dismissOverlay() })
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
            // Seed the active profile's default categories at launch (idempotent) so a
            // category-scoped budget never references a category that hasn't synced to the
            // server — previously categories were seeded only lazily on the Categories
            // screen, so a budget could push a category_id the server lacked and FK-fail.
            seedCategoriesForActive()
            // One-time per-profile GST-default backfill (spec §1/§4.2): upgrading installs
            // seeded their categories BEFORE `gstFreeDefault` existed, so groceries stayed
            // taxable and over-claimed GST via ÷11. `backfillGstDefaults` flips groceries →
            // gstFreeDefault and is idempotent (UserDefaults-guarded per profile), so running
            // it on every launch/activation is safe.
            backfillGstDefaultsForActive()
            await sync.sync()
        }
        // Re-run the (idempotent) backfill when the active profile changes, so switching to a
        // not-yet-backfilled profile fixes its groceries GST default too.
        .onChange(of: profiles.activeProfileId) { _, _ in
            seedCategoriesForActive()
            backfillGstDefaultsForActive()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await sync.sync() }
            }
        }
        // When the network path returns (offline → online), re-sync immediately rather than
        // waiting for the next foreground — clears a stale "Offline" the moment we're back.
        .onChange(of: reachability.isOnline) { wasOnline, isOnline in
            if isOnline && !wasOnline {
                Task { await sync.sync() }
            }
        }
    }

    /// One-time GST-default backfill for the ACTIVE profile (spec §1/§4.2). Idempotent and
    /// guarded by a per-profile UserDefaults flag inside `backfillGstDefaults`, so it is safe
    /// to call on every launch and on every active-profile change. Skips when there is no
    /// active profile yet (empty id during the rescope handoff).
    private func backfillGstDefaultsForActive() {
        let pid = profiles.activeProfileId
        guard !pid.isEmpty else { return }
        CategorySeeder.backfillGstDefaults(profileId: pid, context: profiles.context, sync: sync)
    }

    /// Seed the active profile's default categories at launch / profile switch (idempotent,
    /// insert-only) so category-scoped budgets always reference a category that syncs to the
    /// server first. Skips when there is no active profile yet (rescope handoff).
    private func seedCategoriesForActive() {
        let pid = profiles.activeProfileId
        guard !pid.isEmpty else { return }
        CategorySeeder.ensure(profileId: pid, userId: profiles.userId,
                              context: profiles.context, sync: sync)
    }

    // MARK: - Tab content

    @ViewBuilder
    private func tabContent(accent: AccentPalette) -> some View {
        switch router.tab {
        case .home:
            homeStub(accent: accent)
        case .activity:
            ActivityTabView(context: profiles.context, profileId: profiles.activeProfileId,
                            reloadToken: activityReloadToken,
                            onOpenReceipt: { router.present(.receiptDetail(id: $0)) },
                            onSnap: { router.present(.capture) })
        case .reports:
            ReportsView(
                context: profiles.context,
                userId: profiles.userId,
                profileId: profiles.activeProfileId,
                profileName: profiles.activeProfile?.name ?? "",
                startMonth: profiles.activeFinancialYearStartMonth(),
                onOpenExport: { period in basExportPinned = false; exportPeriod = period; router.present(.export) },
                onOpenMileage: { router.present(.mileage) },
                onOpenWFH: { router.present(.wfh) },
                profileType: profiles.activeProfile?.type ?? "personal",
                gstRegistered: profiles.activeProfile?.gstRegistered ?? false,
                basDue: BasSchedule.nextDue(basPeriodForActive, on: Epoch.now()),
                basNetCents: basNetCentsForActive,
                basLodged: basLodgedForActive,
                onOpenBas: { router.present(.bas) }
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
                onOpenExport: { basExportPinned = false; router.present(.export) },
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
                // Top bar — profile switcher + alerts bell (design TopBar)
                HStack(spacing: 8) {
                    ProfileSwitcherHeader(
                        store: profiles,
                        onTapSwitch: { router.go(.overlay(.profilePicker)) }
                    )
                    Spacer(minLength: 8)
                    Button { router.present(.alerts) } label: { bellButton(accent: accent) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AccessibilityID.homeAlertsBell)
                }
                .padding(.horizontal, 18).padding(.top, 12)

                // Net-this-month gradient hero
                HomeSummaryCard(profileId: profiles.activeProfileId,
                                isBusiness: profiles.activeProfile?.type == ProfileType.business.rawValue)
                    .padding(.horizontal, 18).padding(.top, 16)

                // Snap-a-receipt feature CTA
                HomeSnapCTA { router.present(.capture) }
                    .padding(.horizontal, 18).padding(.top, 14)

                // Quick actions — 4 vertical tiles, per profile type
                quickActionRow(accent: accent)
                    .padding(.horizontal, 18).padding(.top, 18)

                HomeRecentReceipts(profileId: profiles.activeProfileId,
                                   onSeeAll: { router.go(.activity) },
                                   onOpenReceipt: { router.present(.receiptDetail(id: $0)) })
                    .padding(.horizontal, 18).padding(.top, 20)

                BudgetTrackerView(
                    context: profiles.context, sync: sync,
                    userId: profiles.userId, profileId: profiles.activeProfileId,
                    reloadToken: activityReloadToken,
                    onEdit: { router.present(.budgets) },
                    onTapBudget: { router.openBudget($0) },
                    onAdd: { router.openBudget(nil) }
                )
                .padding(.horizontal, 18).padding(.top, 18)
            }
            // Home a11y CONTAINER: `.contain` lets `shell.home` carry this identifier
            // WITHOUT flattening the subtree (profile.switcher / bell / budget-row /
            // quick-action ids all stay queryable).
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
        let today = ExportDateFormatter.shared.string(from: Date())
        let overdue = InvoiceListViewModel.overdueCount(context: profiles.context,
                                                        profileId: pid, today: today)
        return AlertCache().unreadCount(AlertFeed.items(inputs: inputs, now: Epoch.now())) + overdue
    }

    /// Home alerts bell — square rounded paper button with an accent unread dot
    /// (design TopBar bell), replacing the old accent IconCircle.
    private func bellButton(accent: AccentPalette) -> some View {
        Icon(name: "bell", size: 21, color: Palette.ink2)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())   // whole 44×44 is the tap target, not just the glyph
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.line, lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                if unreadAlertCount > 0 {
                    Circle().fill(accent.base).frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(Palette.paper, lineWidth: 2))
                        .padding(.top, 9).padding(.trailing, 10)
                }
            }
            .cardShadow()
    }

    /// The 4-across quick-action row. Action set switches on the active profile type
    /// (business: Quote / Add Manually / Reports / Receipts; personal: Loyalty /
    /// Add Manually / Mileage / WFH), matching the design's HomeScreen.
    @ViewBuilder
    private func quickActionRow(accent: AccentPalette) -> some View {
        let isBusiness = profiles.activeProfile?.type == ProfileType.business.rawValue
        HStack(spacing: 6) {
            if isBusiness {
                quickTile(title: "Create Quote", icon: "receipt", id: AccessibilityID.homeQuickQuote,
                          accent: accent) { router.present(.quotes) }
                quickTile(title: "Invoices", icon: "doc", id: AccessibilityID.homeQuickInvoices,
                          accent: accent) { router.present(.invoices) }
                quickTile(title: "Add Manually", icon: "plus", id: AccessibilityID.homeQuickManual,
                          accent: accent) { router.present(.manual(editId: nil)) }
                quickTile(title: "Reports", icon: "chart", id: AccessibilityID.homeQuickReports,
                          accent: accent) { router.go(.reports) }
            } else {
                quickTile(title: "Loyalty Card", icon: "star", id: AccessibilityID.homeQuickLoyalty,
                          accent: accent) { router.present(.loyalty) }
                quickTile(title: "Add Manually", icon: "plus", id: AccessibilityID.homeQuickManual,
                          accent: accent) { router.present(.manual(editId: nil)) }
                quickTile(title: "Mileage", icon: "car", id: AccessibilityID.homeQuickMileage,
                          accent: accent) { router.present(.mileage) }
                quickTile(title: "WFH log", icon: "wfh", id: AccessibilityID.homeQuickWFH,
                          accent: accent) { router.present(.wfh) }
            }
        }
    }

    /// One Home quick-action tile — vertical 52×52 paper icon square + label below.
    @ViewBuilder
    private func quickTile(title: String, icon: String, id: String,
                           accent: AccentPalette, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Icon(name: icon, size: 23, color: accent.base)
                    .frame(width: 52, height: 52)
                    .background(Palette.paper, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(Palette.line, lineWidth: 1)
                        .allowsHitTesting(false))   // decorative border must not swallow the tile tap
                    .cardShadow()
                Text(title).font(.ui(11.5, .semibold)).foregroundStyle(Palette.ink2)
                    .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())   // whole tile column is the hit target
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
                case .capture, .mileage, .wfh, .manual, .receiptDetail, .budgets, .budgetEditor, .alerts, .notificationSettings,
                     .loyalty, .loyaltyAdd, .loyaltyCard, .quotes, .bas, .quoteEditor,
                     .invoices, .invoiceEditor,
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
                                               Overlay.quotes.id, Overlay.bas.id, Overlay.emailIn.id,
                                               Overlay.invoices.id,
                                               Overlay.tax.id, Overlay.categories.id,
                                               Overlay.account.id, Overlay.privacy.id, Overlay.changeEmail.id]
                if newValue == nil, let cur = router.overlay,
                   !fullScreen.contains(cur.id),
                   !cur.id.hasPrefix("budgetEditor"), !cur.id.hasPrefix("loyaltyCard"),
                   !cur.id.hasPrefix("quoteEditor"), !cur.id.hasPrefix("invoiceEditor"),
                   !cur.id.hasPrefix("emailInReview"),
                   !cur.id.hasPrefix("ruleEditor"), !cur.id.hasPrefix("profileDetail"),
                   !cur.id.hasPrefix("manual"), !cur.id.hasPrefix("receiptDetail") {
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
            // Top-anchored on the cream sheet surface (the system .sheet owns the
            // grabber + rounded corners) — no bottom-anchored white sub-panel, which
            // previously read as a sheet-within-a-sheet. Matches AddProfileView.
            ProfilePickerSheet(
                store: profiles,
                onAddProfile: { router.go(.overlay(.addProfile)) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                onClose: { basExportPinned = false; router.dismissOverlay() },
                basPinned: basExportPinned,
                paygInstalmentCents: basExportPinned
                    ? BasLocalStore().paygInstalmentCents(
                        profileId: profiles.activeProfileId,
                        periodKey: BasPeriodKey.make(
                            window: basWindowForActive,
                            basPeriod: basPeriodForActive,
                            startMonth: profiles.activeFinancialYearStartMonth()))
                    : 0
            )
            .frame(maxHeight: .infinity, alignment: .bottom)
            .background(Palette.cream)
        case .capture:
            EmptyView()  // handled by the full-screen capture overlay
        case .receiptDetail, .mileage, .wfh, .manual, .budgets, .budgetEditor, .alerts, .notificationSettings,
             .loyalty, .loyaltyAdd, .loyaltyCard, .quotes, .bas, .quoteEditor,
             .invoices, .invoiceEditor,
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
            onClose: { router.dismissOverlay(); activityReloadToken += 1 }
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
        return LiveAPIClient(baseURL: URL(string: "https://api.snapceipt.cc")!, auth: auth)
        #endif
    }

    /// The export range + detail-card values for the currently-selected Reports period,
    /// scoped to the active profile. `exportPeriod` is set when the user taps Export in
    /// ReportsView, so this window reflects whichever period was active (spec §2.8/§6).
    /// Receipts count = transactions in range; locally we show the in-range txn count.
    ///
    /// BAS-pinned exception (spec §4.7): when the sheet is the BAS pack (`basExportPinned`),
    /// the window is pinned to `basWindowForActive` — the SAME window that keys the PAYG
    /// instalment (~:600) and drives the on-screen Simpler-BAS spine — so the emitted
    /// from/to can never drift from the spine for a quarterly profile (a `.month` default
    /// here would otherwise POST a monthly range with the quarterly PAYG).
    private var exportWindow: (from: String, to: String, label: String,
                               receiptsCount: Int, deductibleCents: Int,
                               savedAccountantEmail: String?) {
        let now = Epoch.now()
        let window = BasExportWindow.resolve(
            pinned: basExportPinned,
            basWindow: basWindowForActive,
            defaultPeriod: exportPeriod,
            now: now,
            startMonth: profiles.activeFinancialYearStartMonth())
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

    /// The active profile's BAS period (local pref; defaults quarterly).
    private var basPeriodForActive: BasPeriod {
        BasPeriod(rawValue: UserDefaults.standard
            .string(forKey: "sc.tax.\(profiles.activeProfileId).basPeriod") ?? "") ?? .quarterly
    }

    /// The active profile's BAS window (current in-progress period).
    private var basWindowForActive: Period.Window {
        let p: Period = (basPeriodForActive == .quarterly) ? .quarter : .month
        return p.window(now: Epoch.now(), startMonth: profiles.activeFinancialYearStartMonth())
    }

    /// Net GST cents for the Reports BAS card (one engine pass over the in-window txns).
    private var basNetCentsForActive: Int {
        guard profiles.activeProfile?.type == "business",
              profiles.activeProfile?.gstRegistered == true else { return 0 }
        let pid = profiles.activeProfileId
        let rows = (try? profiles.context.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil }))) ?? []
        let iso = ExportDateFormatter.shared
        let w = basWindowForActive
        let txns = rows.filter { iso.date(from: $0.txnDate).map { $0 >= w.start && $0 < w.end } ?? false }
            .map { BasEngine.Txn(amountCents: $0.amountCents, gstFree: $0.gstFree,
                                 capital: $0.capital, txnDate: $0.txnDate) }
        let payg = BasLocalStore().paygInstalmentCents(
            profileId: pid,
            periodKey: BasPeriodKey.make(window: w, basPeriod: basPeriodForActive,
                                         startMonth: profiles.activeFinancialYearStartMonth()))
        return BasEngine.compute(txns: txns, gstRegistered: true,
                                 manual: BasEngine.Manual(paygInstalmentCents: payg)).netGstCents
    }

    /// Whether the active profile's current BAS period has a lodged snapshot.
    private var basLodgedForActive: Bool {
        let w = basWindowForActive
        let key = BasPeriodKey.make(window: w, basPeriod: basPeriodForActive,
                                    startMonth: profiles.activeFinancialYearStartMonth())
        return BasLocalStore().lodgedSnapshot(profileId: profiles.activeProfileId, periodKey: key) != nil
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
        // -uiTestCaptureCamera: suppress the canned feed so the flow stays on `.camera`,
        // letting the import-affordance UI test inspect the camera stage.
        if AppLaunch.current.captureCamera { return nil }
        return AppLaunch.current.cannedScan
        #else
        return nil
        #endif
    }
}

/// Full-screen biometric lock cover (spec §6). Shown over the authed shell whenever
/// `AppLockController.isLocked` is true (cold launch + return-from-background while the
/// lock is enabled). Opaque `Palette.cream` so the underlying shell is hidden, with the
/// app mark + an Unlock button that re-runs `LAContext` via `onUnlock`.
struct LockScreen: View {
    let onUnlock: () -> Void

    var body: some View {
        ZStack {
            Palette.cream.ignoresSafeArea()
            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(Palette.paper2).frame(width: 88, height: 88)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                }
                Text("Snapceipt is locked")
                    .font(.display(22, .bold)).foregroundStyle(Palette.ink)
                Text("Unlock with Face ID / Touch ID to continue.")
                    .font(.ui(14)).foregroundStyle(Palette.ink2)
                    .multilineTextAlignment(.center)
                Button(action: onUnlock) {
                    Label("Unlock", systemImage: "faceid")
                        .font(.ui(16, .semibold))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 22).padding(.vertical, 13)
                        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Palette.line2, lineWidth: 1))
                        .cardShadow()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.appLockUnlock)
                .padding(.top, 6)
            }
            .padding(.horizontal, 32)
        }
        .accessibilityElement(children: .contain)
        .onAppear { onUnlock() }   // auto-prompt biometrics the moment the cover appears
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
        .environment(AppLockController(canEvaluate: { false }, evaluate: { true }))
        .modelContainer(container)
}
#endif
