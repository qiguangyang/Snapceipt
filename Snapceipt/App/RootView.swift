import SwiftUI
import SwiftData

/// Top-level auth + first-run gate.
///
/// Composition order (foundation): Task 1 shipped the placeholder shell; Task 12
/// (here) gates on auth + first profile; Task 14 will replace `ShellPlaceholder`
/// with the real tab-bar shell. Routing:
/// - no session → `SignInView`
/// - magic link sent / verifying → `MagicLinkWaitView`
/// - signed in but no profile → `OnboardingView`
/// - signed in with a profile → the shell
struct RootView: View {
    @Environment(AuthViewModel.self) private var authVM
    /// Live count of non-deleted profiles drives the "needs onboarding" gate.
    @Query(filter: #Predicate<Profile> { $0.deletedAt == nil }) private var profiles: [Profile]

    var body: some View {
        Group {
            switch authVM.state {
            case .signedIn:
                if profiles.isEmpty {
                    OnboardingView(onFinished: {
                        // No-op: inserting the first profile flips `profiles.isEmpty`,
                        // which re-renders this view straight into the shell.
                    })
                } else {
                    ShellPlaceholder()
                }
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
        .animation(.easeInOut(duration: 0.28), value: profiles.isEmpty)
    }
}

/// Temporary signed-in shell. Replaced by the real tab-bar shell (TabBar + Router +
/// overlays + ToastHost + OfflineBanner + SyncStatusView) in Task 14.
private struct ShellPlaceholder: View {
    var body: some View {
        ZStack {
            Palette.cream.ignoresSafeArea()
            Text("Snapceipt")
                .font(.display(34, .bold))
                .foregroundStyle(Palette.ink)
        }
    }
}

#if DEBUG
#Preview {
    RootView()
        .environment(AuthViewModel(
            api: PreviewAPIClient(),
            auth: AuthStore(keychain: Keychain(service: "sc.preview"))
        ))
        .environment(AuthStore(keychain: Keychain(service: "sc.preview")))
        .modelContainer(makeSnapceiptContainer(inMemory: true))
}
#endif
