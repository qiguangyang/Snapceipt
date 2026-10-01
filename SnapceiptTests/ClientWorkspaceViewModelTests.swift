import Foundation
import SwiftData
import Testing
@testable import Snapceipt

@MainActor struct ClientWorkspaceViewModelTests {
    func fixture() throws -> (ModelContext, ClientWorkspaceViewModel, Client) {
        let context = ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
        let client = Client(userId: "u", profileId: "p", name: "Taylor", mobilePhone: "0400123456")
        context.insert(client)
        context.insert(Profile(id: "p", userId: "u", name: "Work", type: "business", accent1: "a", accent2: "b", accent3: "c"))
        try context.save()
        return (context, ClientWorkspaceViewModel(context: context, sync: MockSyncEngine(), userId: "u", profileId: "p", initialClientId: client.id), client)
    }
    @Test func hubActionsReturnToSelectedClient() throws {
        let (_, vm, client) = try fixture()
        vm.createDocument(kind: .quote)
        #expect(vm.presentation != nil)
        vm.closePresentation()
        #expect(vm.selectedClientId == client.id)
        vm.createDocument(kind: .invoice)
        vm.closePresentation()
        #expect(vm.selectedClientId == client.id)
    }
    @Test func repeatActionDoubleTapGuard() throws {
        let (context, vm, client) = try fixture()
        let q = Quote(userId: "u", profileId: "p", clientId: client.id)
        context.insert(q); context.insert(QuoteLineItem(userId: "u", quoteId: q.id, itemDescription: "Work", unitPriceCents: 100)); try context.save()
        vm.reload()
        let source = try #require(vm.history.documents.first)
        vm.createAgain(source); vm.createAgain(source)
        let uid = "u", pid = "p"
        #expect(try context.fetch(FetchDescriptor<Quote>(predicate: #Predicate { $0.userId == uid && $0.profileId == pid })).count == 2)
    }
    @Test func reloadAfterSync() throws {
        let (context, vm, _) = try fixture()
        context.insert(Client(userId: "u", profileId: "p", name: "Second")); try context.save()
        vm.reload()
        #expect(vm.clients.count == 2)
        vm.search = "040012"
        #expect(vm.filteredClients.count == 1)
    }
    @Test func lateFollowUpSaveDoesNotCloseNewDocument() throws {
        let (_, vm, _) = try fixture()
        vm.presentation = .followUp(nil)
        let prior = try #require(vm.presentation)
        let generation = vm.presentationGeneration
        vm.closePresentation(); vm.createDocument(kind: .quote)
        let current = vm.presentation
        vm.finishPresentation(prior, generation: generation)
        #expect(vm.presentation == current)
    }
    @Test func lateFollowUpSaveDoesNotCloseReopenedNewReminder() throws {
        let (_, vm, _) = try fixture()
        vm.presentation = .followUp(nil)
        let priorGeneration = vm.presentationGeneration
        vm.closePresentation()
        vm.presentation = .followUp(nil)
        vm.finishPresentation(.followUp(nil), generation: priorGeneration)
        #expect(vm.presentation == .followUp(nil))
        vm.finishPresentation(.followUp(nil), generation: vm.presentationGeneration)
        #expect(vm.presentation == nil)
    }
    @Test func personalProfileHasNoClientsEntry() {
        #expect(ClientWorkspaceViewModel.isAvailable(profileType: "personal") == false)
        #expect(ClientWorkspaceViewModel.isAvailable(profileType: "business"))
    }
}

@MainActor struct ClientDocumentPresentationTests {
    @Test func failedInvoiceSaveDoesNotReturnToClientAndSuccessfulSaveDoes() throws {
        let context = ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
        context.insert(Profile(id: "p", userId: "u", name: "Work", type: "business", accent1: "a", accent2: "b", accent3: "c"))
        let client = Client(userId: "u", profileId: "p", name: "Taylor")
        context.insert(client); try context.save()
        let sync = MockSyncEngine()
        var returns = 0
        let view = InvoiceEditorView(context: context, sync: sync, api: PreviewAPIClient(), userId: "u", profileId: "p", invoiceId: nil, onClose: {}, onSavedDraft: { returns += 1 })
        struct SaveError: Error {}
        let failure = InvoiceEditorViewModel(context: context, sync: sync, userId: "u", profileId: "p", persist: { _ in throw SaveError() })
        failure.load(id: nil); failure.setClient(ClientSelection(client))
        view.saveDraft(failure)
        #expect(returns == 0); #expect(failure.errorMessage != nil)
        let success = InvoiceEditorViewModel(context: context, sync: sync, userId: "u", profileId: "p")
        success.load(id: nil); success.setClient(ClientSelection(client))
        view.saveDraft(success)
        #expect(returns == 1)
        #expect(try context.fetch(FetchDescriptor<Invoice>()).count == 1)
    }
    @Test func reviewCopyOnlyAppliesToCreatedAgainDraft() throws {
        let context = ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
        context.insert(Profile(id: "p", userId: "u", name: "Work", type: "business", accent1: "a", accent2: "b", accent3: "c"))
        let c = Client(userId: "u", profileId: "p", name: "Taylor")
        let q = Quote(userId: "u", profileId: "p", clientId: c.id)
        context.insert(c); context.insert(q); context.insert(QuoteLineItem(userId: "u", quoteId: q.id, itemDescription: "Work", unitPriceCents: 100)); try context.save()
        let vm = ClientWorkspaceViewModel(context: context, sync: MockSyncEngine(), userId: "u", profileId: "p", initialClientId: c.id)
        vm.createAgain(try #require(vm.history.documents.first))
        if case .quote(let id) = vm.presentation { #expect(vm.needsPriceReview(id)) }
        else { Issue.record("Expected repeated quote editor") }
        #expect(!vm.needsPriceReview(q.id))
        vm.convertedToInvoice("converted")
        #expect(vm.presentation == .invoice("converted"))
        #expect(vm.needsPriceReview("converted"))
        #expect(vm.selectedClientId == c.id)
    }
}
