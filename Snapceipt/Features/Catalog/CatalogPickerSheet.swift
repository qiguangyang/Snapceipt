import SwiftUI
import SwiftData

struct CatalogPickerSheet: View {
    let context: ModelContext
    let sync: any SyncEnqueuing
    let userId: String
    let profileId: String
    let onPick: (CatalogItem) throws -> Void
    let onClose: () -> Void
    @State private var search = ""
    @State private var items: [CatalogItem] = []
    @State private var errorMessage: String?
    @State private var showEditor = false
    private var store: CatalogStore { CatalogStore(context: context, sync: sync, userId: userId, profileId: profileId) }

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                ForEach(items) { item in
                    Button {
                        do { try onPick(item) }
                        catch { errorMessage = error.localizedDescription }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(item.itemDescription)
                            Text("\(item.unitLabel.map { "\($0) · " } ?? "")\(Double(item.unitPriceCents) / 100, specifier: "%.2f") excl. GST")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if items.isEmpty && errorMessage == nil { Text("No saved items").foregroundStyle(.secondary) }
            }
            .navigationTitle("Saved items")
            .searchable(text: $search, prompt: "Search descriptions")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close", action: onClose) }
                ToolbarItem(placement: .primaryAction) { Button("Add item", systemImage: "plus") { showEditor = true } }
            }
            .onAppear(perform: reload)
            .onChange(of: search) { _, _ in reload() }
            .sheet(isPresented: $showEditor) { CatalogEditorView(store: store, item: nil, onSaved: reload) }
        }
    }
    private func reload() {
        do { items = try store.list(search: search); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
}
