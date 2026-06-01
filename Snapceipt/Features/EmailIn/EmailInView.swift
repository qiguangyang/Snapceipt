import SwiftUI
import SwiftData

struct EmailInView: View {
    @State private var vm: EmailInViewModel
    let onClose: () -> Void
    let onReview: (String) -> Void

    init(context: ModelContext, sync: any SyncEnqueuing, api: any APIClient,
         userId: String, profileId: String,
         onClose: @escaping () -> Void, onReview: @escaping (String) -> Void) {
        _vm = State(initialValue: EmailInViewModel(context: context, sync: sync, api: api,
                                                   userId: userId, profileId: profileId))
        self.onClose = onClose
        self.onReview = onReview
    }

    var body: some View {
        VStack { Text("Email-in") }
            .accessibilityIdentifier(AccessibilityID.emailInScreen)
            .task { await vm.loadAddress() }
    }
}
