import AppKit
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

final class DesktopPreferencesTests: XCTestCase {
    @MainActor func testSystemReopenRoutesWindowThenActivationWithoutPresentingTestWindow() throws {
        let delegate = DesktopApplicationDelegate()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        XCTAssertFalse(window.isVisible)
        delegate.mainWindow = window

        var events: [String] = []
        delegate.bringMainWindowToFront = { candidate in
            XCTAssertTrue(candidate === window)
            XCTAssertFalse(candidate.isVisible)
            events.append("front")
        }
        delegate.activateApplication = { application in
            XCTAssertTrue(application === NSApplication.shared)
            events.append("activate")
        }

        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        XCTAssertEqual(events, ["front", "activate"])
        XCTAssertFalse(window.isVisible)
    }

    @MainActor func testInterfaceLanguageAndMenuPreferencePersistWithoutChangingRecognition() throws {
        let name = "Clavune.DesktopFixture." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = try CoordinatorFixture(preferences: defaults)
        first.coordinator.language = .de
        first.coordinator.uiLanguage = .english
        first.coordinator.menuBarEnabled = false
        XCTAssertEqual(first.coordinator.language, .de)
        first.coordinator.uiLanguage = .german
        XCTAssertEqual(first.coordinator.language, .de)
        let second = try CoordinatorFixture(preferences: defaults)
        XCTAssertEqual(second.coordinator.uiLanguage, .german)
        XCTAssertFalse(second.coordinator.menuBarEnabled)
        XCTAssertEqual(second.coordinator.language, .de)
        XCTAssertEqual(second.resources.counts.value.opened, 0)
        XCTAssertEqual(second.inference.counts.value.loads, 0)
    }
    @MainActor func testEveryRecognitionModePersistsIndependentlyAcrossRelaunch() throws {
        let name = "Clavune.RecognitionFixture." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for mode in LanguageMode.allCases.reversed() {
            let first = try CoordinatorFixture(preferences: defaults)
            first.coordinator.language = mode
            first.coordinator.uiLanguage = .german
            XCTAssertEqual(defaults.string(forKey: "recognitionLanguage"), mode.rawValue)
            first.coordinator.uiLanguage = .english
            let reopened = try CoordinatorFixture(preferences: defaults)
            XCTAssertEqual(reopened.coordinator.language, mode)
            XCTAssertEqual(reopened.coordinator.uiLanguage, .english)
            XCTAssertFalse(reopened.coordinator.hotkeyEnabled)
            XCTAssertEqual(reopened.resources.counts.value.opened, 0)
            XCTAssertEqual(reopened.inference.counts.value.loads, 0)
            XCTAssertEqual(reopened.permissionCalls, 0)
        }
    }

    @MainActor func testMissingOrInvalidRecognitionPreferenceUsesAutoWithoutRewritingDefaults() throws {
        let name = "Clavune.RecognitionFixture." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let absent = try CoordinatorFixture(preferences: defaults)
        XCTAssertEqual(absent.coordinator.language, .auto)
        XCTAssertNil(defaults.persistentDomain(forName: name)?["recognitionLanguage"])
        for value in ["unknown-mode", "", 42] as [Any] {
            defaults.set(value, forKey: "recognitionLanguage")
            let before = defaults.persistentDomain(forName: name) as NSDictionary?
            let reopened = try CoordinatorFixture(preferences: defaults)
            XCTAssertEqual(reopened.coordinator.language, .auto)
            XCTAssertEqual(defaults.persistentDomain(forName: name) as NSDictionary?, before)
        }
    }

    @MainActor func testRecognitionPreferenceStaysInItsQADomainWithoutRegistrationFallback() throws {
        let config = try AppLaunchConfiguration.parse(environment: ["CLAVUNE_QA_PROFILE": "language-" + String(UUID().uuidString.prefix(20))])
        let preferences = try config.makePreferences()
        let defaults = try XCTUnwrap(preferences.defaults)
        let name = try XCTUnwrap(config.preferenceSuite)
        let registration = defaults.volatileDomain(forName: UserDefaults.registrationDomain)
        defer {
            defaults.removePersistentDomain(forName: name)
            defaults.removeVolatileDomain(forName: UserDefaults.registrationDomain)
            defaults.setVolatileDomain(registration, forName: UserDefaults.registrationDomain)
        }
        defaults.register(defaults: ["recognitionLanguage": "de"])
        let first = try CoordinatorFixture(preferences: defaults, launchConfiguration: config)
        XCTAssertEqual(first.coordinator.language, .auto, "QA must ignore registered fallback")
        first.coordinator.language = .en
        let reopened = try CoordinatorFixture(preferences: defaults, launchConfiguration: config)
        XCTAssertEqual(reopened.coordinator.language, .en)
        XCTAssertEqual(defaults.persistentDomain(forName: name)?["recognitionLanguage"] as? String, "en")
        XCTAssertFalse(reopened.coordinator.canStart)
        XCTAssertEqual(reopened.resources.counts.value.opened, 0)
        XCTAssertEqual(reopened.inference.counts.value.loads, 0)
        XCTAssertEqual(reopened.permissionCalls, 0)
    }

    func testEnglishTranslatesStatusErrorsAndDynamicModelSuffix() {
        XCTAssertEqual(UILanguage.english.text("Aufnahme läuft"), "Recording")
        XCTAssertEqual(UILanguage.german.text("Aufnahme läuft"), "Aufnahme läuft")
        XCTAssertEqual(UILanguage.english.text("fixture.bin — Hash geprüft, Qualität noch ungemessen"),
                       "fixture.bin — hash verified, quality still unmeasured")
        XCTAssertEqual(UILanguage.english.text("fixture.bin: 123 / 456 Bytes"),
                       "fixture.bin: 123 / 456 bytes")
        XCTAssertEqual(UILanguage.english.text("Dateigröße: %@ (%lld Bytes)"),
                       "File size: %@ (%lld bytes)")
        XCTAssertEqual(UILanguage.english.text("Quelle: %@ · Revision %@"),
                       "Source: %@ · revision %@")
        XCTAssertEqual(UILanguage.english.text("Modell-Download wird vorbereitet …"), "Preparing model download…")
        XCTAssertEqual(UILanguage.english.text(DictationError.permissionDenied.localizedDescription),
                       "Microphone access is not allowed. Recording did not start.")
    }
    func testCatalogueRoleIdentifiersAreReadableInBothInterfaceLanguages() {
        let roles = [
            ("comparison-candidate", "Vergleichskandidat", "Comparison candidate"),
            ("product-candidate", "Produktkandidat", "Product candidate"),
            ("reference-candidate", "Referenzkandidat", "Reference candidate"),
        ]
        for (raw, german, english) in roles {
            XCTAssertEqual(UILanguage.german.modelRole(raw), german)
            XCTAssertEqual(UILanguage.english.modelRole(raw), english)
        }
        XCTAssertEqual(UILanguage.german.modelRole("test-fixture"), "test-fixture")
        XCTAssertEqual(UILanguage.english.modelRole("test-fixture"), "test-fixture")
    }
    func testPCMMetricAndFileImportGuidanceUseTheSelectedInterfaceLanguage() {
        let pcmFormat = "PCM: %@ Abtastwerte"
        XCTAssertEqual(String(format: UILanguage.english.text(pcmFormat), "16000"), "PCM: 16000 samples")
        XCTAssertEqual(String(format: UILanguage.german.text(pcmFormat), "16000"), "PCM: 16000 Abtastwerte")
        XCTAssertEqual(UILanguage.english.text("Dateiimport nicht abgeschlossen"), "Audio import did not complete")
        XCTAssertEqual(UILanguage.english.text("Mikrofoneingabe bleibt geschlossen. Wähle oben „Audiodatei importieren …“, um es erneut zu versuchen."),
                       "The microphone remains off. Choose “Import audio file…” above to try again.")
        XCTAssertEqual(UILanguage.german.text("Dateiimport nicht abgeschlossen"), "Dateiimport nicht abgeschlossen")
    }
    func testModelDownloadFailuresFollowTheSelectedInterfaceLanguage() {
        let failures: [ModelDownloadFailure] = [
            .unavailableSource, .invalidSource, .insufficientStorage, .unsafePartial,
            .rejectedResponse, .invalidRedirect, .incompleteTransfer, .transferTooLarge, .changedSource
        ]
        for failure in failures {
            XCTAssertEqual(UILanguage.german.downloadFailureMessage(for: failure), failure.localizedDescription)
            XCTAssertNotEqual(UILanguage.english.downloadFailureMessage(for: failure), failure.localizedDescription)
        }
        XCTAssertEqual(UILanguage.german.downloadFailureMessage(for: URLError(.networkConnectionLost)),
                       "Der Modelldownload wurde unterbrochen. Prüfe die Verbindung und wähle den Download erneut; Teildaten werden nur bei passender Quellenprüfung fortgesetzt.")
        XCTAssertEqual(UILanguage.english.downloadFailureMessage(for: URLError(.networkConnectionLost)),
                       "The model download was interrupted. Check your connection and choose the download again; partial bytes resume only after the source is validated.")
        XCTAssertEqual(UILanguage.english.downloadFailureMessage(for: NSError(domain: "synthetic", code: 1)),
                       "The model download failed. Check your connection and available storage, then try again.")
    }
    @MainActor func testSystemQuitWaitsForCoordinatorDrainBeforeTerminationIsAllowed() async throws {
        let fixture = try CoordinatorFixture()
        let delegate = DesktopApplicationDelegate()
        delegate.coordinator = fixture.coordinator
        fixture.terminated = expectation(description: "Coordinator reached safe termination")
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        await fulfillment(of: [try XCTUnwrap(fixture.terminated)], timeout: 2)
        XCTAssertTrue(fixture.coordinator.terminationReady)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        XCTAssertEqual(fixture.terminationCalls, 1)
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }
    @MainActor func testRepeatedSystemQuitCannotBypassHeldUnloadDrain() async throws {
        let fixture = try CoordinatorFixture()
        let delegate = DesktopApplicationDelegate()
        delegate.coordinator = fixture.coordinator
        let gate = ControlledDelivery()
        let unloading = expectation(description: "system quit reached unload")
        fixture.inference.unloadGate = gate
        fixture.inference.onUnload = unloading
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        await fulfillment(of: [unloading], timeout: 2)
        await gate.waitUntilSuspended()
        XCTAssertFalse(fixture.coordinator.terminationReady)
        XCTAssertEqual(fixture.terminationCalls, 0)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertEqual(fixture.inference.counts.value.unloads, 1)
        XCTAssertEqual(fixture.terminationCalls, 0)
        let terminated = expectation(description: "termination after held drain")
        fixture.terminated = terminated
        await gate.release()
        await fulfillment(of: [terminated], timeout: 2)
        XCTAssertTrue(fixture.coordinator.terminationReady)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        XCTAssertEqual(fixture.terminationCalls, 1)
    }

}
