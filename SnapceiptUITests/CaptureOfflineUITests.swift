import XCTest

/// J18b: offline capture falls back to HeuristicParser and queues in the outbox.
final class CaptureOfflineUITests: UITestCase {
    func testOfflineCaptureFallsBackAndQueues() {
        app.launchArguments += ["-uiTestStub", "-uiTestSeed", "-uiTestOffline"]
        app.launch()
        app.buttons[AccessibilityID.tabSnap].firstMatch.tap()
        // Review still appears — filled by HeuristicParser (the network extractor threw).
        let save = app.buttons[AccessibilityID.captureSave]
        XCTAssertTrue(save.waitForExistence(timeout: 12),
                      "Offline review (HeuristicParser fallback) did not appear")
        save.tap()
        // The receipt is QUEUED (outbox), not synced — assert the queued surface.
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.captureQueuedBadge].firstMatch
                        .waitForExistence(timeout: 8),
                      "Offline save did not surface the queued/outbox state")
    }
}
