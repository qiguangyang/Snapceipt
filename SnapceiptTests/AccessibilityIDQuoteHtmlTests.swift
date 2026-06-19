import Testing
@testable import Snapceipt

@Suite("AccessibilityID — quote-html + tax-business ids")
struct AccessibilityIDQuoteHtmlTests {
    @Test("ids are stable strings")
    func ids() {
        #expect(AccessibilityID.quoteEditorShareMenu == "quote.editor.shareMenu")
        #expect(AccessibilityID.quoteEditorShareLink == "quote.editor.shareLink")
        #expect(AccessibilityID.quoteEditorGeneratePdf == "quote.editor.generatePdf")
        #expect(AccessibilityID.taxGstRateControl == "tax.gstRate.control")
        #expect(AccessibilityID.taxGstRateCustom == "tax.gstRate.custom")
        #expect(AccessibilityID.taxBusinessEmailField == "tax.business.email")
        #expect(AccessibilityID.taxBusinessPhoneField == "tax.business.phone")
        #expect(AccessibilityID.taxBusinessWebsiteField == "tax.business.website")
        #expect(AccessibilityID.taxBusinessAddressField == "tax.business.address")
        #expect(AccessibilityID.taxBusinessLogoPicker == "tax.business.logo.picker")
        #expect(AccessibilityID.taxBusinessLogoPreview == "tax.business.logo.preview")
        #expect(AccessibilityID.taxBankDetailsField == "tax.bank.details")
    }
}
