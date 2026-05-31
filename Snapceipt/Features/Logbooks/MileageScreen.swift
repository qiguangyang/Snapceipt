// MileageScreen.swift
import SwiftUI
import SwiftData

struct MileageScreen: View {
    let context: ModelContext
    let sync: any SyncEnqueuing
    let userId: String
    let profileId: String
    let startMonth: Int
    let onClose: () -> Void
    var body: some View {
        Color.clear.accessibilityIdentifier(AccessibilityID.mileageScreen)
    }
}
