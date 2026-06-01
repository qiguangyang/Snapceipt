import SwiftUI
import SwiftData

struct EmailInReviewView: View {
    let vm: EmailInViewModel
    let transactionId: String
    let onClose: () -> Void

    var body: some View {
        VStack { Text("Review") }
            .accessibilityIdentifier(AccessibilityID.emailInReviewScreen)
    }
}
