import SwiftUI
import SwiftData

struct CatalogListView: View {
    let context: ModelContext
    let sync: any SyncEnqueuing
    let userId: String
    let profileId: String
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var items: [CatalogItem] = []
    @State private var editing: CatalogItem?
    @State private var showEditor = false
    @State private var errorMessage: String?
    private var store: CatalogStore { CatalogStore(context: context, sync: sync, userId: userId, profileId: profileId) }

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                ForEach(items) { item in
                    Button { editing = item; showEditor = true } label: {
                        VStack(alignment: .leading) {
                            Text(item.itemDescription)
                            Text("\(item.unitLabel.map { "\($0) · " } ?? "")\(Double(item.unitPriceCents) / 100, specifier: "%.2f") excl. GST")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions { Button("Delete", role: .destructive) { remove(item) } }
                }
                if items.isEmpty && errorMessage == nil { Text("No saved items").foregroundStyle(.secondary) }
            }
            .navigationTitle("Saved items")
            .searchable(text: $search, prompt: "Search descriptions")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Add item", systemImage: "plus") { editing = nil; showEditor = true } }
            }
            .onAppear(perform: reload)
            .onChange(of: search) { _, _ in reload() }
            .sheet(isPresented: $showEditor) { CatalogEditorView(store: store, item: editing, onSaved: reload) }
        }
    }

    private func reload() {
        do { items = try store.list(search: search); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
    private func remove(_ item: CatalogItem) {
        do { try store.delete(id: item.id); reload() }
        catch { errorMessage = error.localizedDescription }
    }
}
