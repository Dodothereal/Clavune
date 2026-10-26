import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

final class AppLaunchConfigurationTests: XCTestCase {
    func testStableComparisonBundleAlwaysLaunchesIntoSyntheticIsolation() throws {
        let qaID = "org.clavune.observatory.qa.20261023.adaptive.main.v3"
        let qa = try AppLaunchConfiguration.parse(environment: [:], bundleIdentifier: qaID)
        XCTAssertTrue(qa.isQA)
        XCTAssertTrue(qa.isFunctionalQA)
        XCTAssertEqual(qa.preferenceSuite,
                       "org.clavune.DevelopmentQA.adaptive-main-v3-20261023")
        XCTAssertFalse(try AppLaunchConfiguration.parse(environment: [:],
            bundleIdentifier: "org.clavune.development").isQA)
        XCTAssertThrowsError(try AppLaunchConfiguration.parse(environment: [
            "CLAVUNE_QA_PROFILE": "another-profile"], bundleIdentifier: qaID))
        XCTAssertThrowsError(try AppLaunchConfiguration.parse(environment: [
            "CLAVUNE_QA_FUNCTIONAL": "live"], bundleIdentifier: qaID))
        let nativePanels = try AppLaunchConfiguration.parse(environment: [
            "CLAVUNE_QA_NATIVE_PANELS": "synthetic-v1"], bundleIdentifier: qaID)
        XCTAssertTrue(nativePanels.isNativePanelQA)
        XCTAssertNil(nativePanels.preferenceSuite)
        let explicit = try AppLaunchConfiguration.parse(environment: [
            "CLAVUNE_QA_PROFILE": "adaptive-main-v3-20261023",
            "CLAVUNE_QA_FUNCTIONAL": "synthetic-v1"], bundleIdentifier: qaID)
        XCTAssertTrue(explicit.isFunctionalQA)
    }
    func testFunctionalQARequiresExactOptInAndValidIsolatedProfile() throws {
        XCTAssertFalse(try AppLaunchConfiguration.parse(environment: [:]).isFunctionalQA)
        for environment in [["CLAVUNE_QA_FUNCTIONAL": "synthetic-v1"],
                            ["CLAVUNE_QA_NATIVE_PANELS": "synthetic-v1"],
                            ["CLAVUNE_QA_PROFILE": "qa", "CLAVUNE_QA_NATIVE_PANELS": "synthetic-v1"],
                            ["CLAVUNE_QA_PROFILE": "qa", "CLAVUNE_QA_FUNCTIONAL": "synthetic-v1",
                             "CLAVUNE_QA_NATIVE_PANELS": "live"],
                            ["CLAVUNE_QA_PROFILE": "qa", "CLAVUNE_QA_FUNCTIONAL": ""],
                            ["CLAVUNE_QA_PROFILE": "qa", "CLAVUNE_QA_FUNCTIONAL": "live"],
                            ["CLAVUNE_QA_PROFILE": "../live", "CLAVUNE_QA_FUNCTIONAL": "synthetic-v1"]] {
            XCTAssertThrowsError(try AppLaunchConfiguration.parse(environment: environment))
        }
        let value = try AppLaunchConfiguration.parse(environment: ["CLAVUNE_QA_PROFILE": "functional-test", "CLAVUNE_QA_FUNCTIONAL": "synthetic-v1"])
        XCTAssertTrue(value.isQA); XCTAssertTrue(value.isFunctionalQA)
        XCTAssertEqual(value.preferenceSuite, "org.clavune.DevelopmentQA.functional-test")
        XCTAssertFalse(value.isNativePanelQA)
    }
    func testNativePanelModeUsesOnlyAnEphemeralPreferenceDomain() throws {
        let profile = "native-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))
        let config = try AppLaunchConfiguration.parse(environment: [
            "CLAVUNE_QA_PROFILE": profile,
            "CLAVUNE_QA_FUNCTIONAL": "synthetic-v1",
            "CLAVUNE_QA_NATIVE_PANELS": "synthetic-v1"])
        XCTAssertTrue(config.isQA)
        XCTAssertTrue(config.isFunctionalQA)
        XCTAssertTrue(config.isNativePanelQA)
        XCTAssertNil(config.preferenceSuite)
        let preferences = try config.makePreferences()
        XCTAssertTrue(preferences.isEphemeral)
        XCTAssertNil(preferences.defaults)
        XCTAssertNil(preferences.isolatedSuite)
        preferences.set("de", forKey: "uiLanguage")
        preferences.set("temporary-selection", forKey: "selectedModelSHA256")
        XCTAssertEqual(preferences.string(forKey: "uiLanguage"), "de")
        XCTAssertEqual(preferences.string(forKey: "selectedModelSHA256"), "temporary-selection")
    }
    @MainActor func testEveryQAModeRejectsHotkeyRegistrationCommands() throws {
        for functional in [false, true] {
            var environment = ["CLAVUNE_QA_PROFILE": "hotkey-test"]
            if functional { environment["CLAVUNE_QA_FUNCTIONAL"] = "synthetic-v1" }
            let config = try AppLaunchConfiguration.parse(environment: environment)
            let fixture = try CoordinatorFixture(launchConfiguration: config)
            fixture.coordinator.setHotkeyEnabled(true)
            fixture.coordinator.configureHotkey()
            fixture.coordinator.setHotkeyEnabled(true)
            XCTAssertFalse(fixture.coordinator.hotkeyEnabled)
            XCTAssertEqual(fixture.hotkeyRegistrar.registrations.count, 0)
            XCTAssertEqual(fixture.hotkeyRegistrar.shortcuts.count, 0)
            XCTAssertFalse(fixture.coordinator.canStart)
            XCTAssertEqual(fixture.permissionCalls, 0)
        }
    }
    @MainActor func testOnboardingModelCatalogueMatchesManifestWithoutSelectingADefault() throws {
        let fixture = try CoordinatorFixture(modelSelectionEnabled: false)
        let catalogue = try XCTUnwrap(fixture.coordinator.modelCatalogue)
        XCTAssertEqual(catalogue.models.map(\.fileName), try ModelStore.candidates().map(\.fileName))
        XCTAssertEqual(catalogue.models.map(\.sizeBytes), try ModelStore.candidates().map(\.sizeBytes))
        XCTAssertFalse(catalogue.releaseApproved); XCTAssertNil(catalogue.defaultModel)
        XCTAssertNil(fixture.coordinator.model)
    }
    func testAbsentOptInKeepsProductionAndInvalidOptInFailsClosed() throws {
        let normal = try AppLaunchConfiguration.parse(environment: [:])
        XCTAssertFalse(normal.isQA)
        XCTAssertNil(normal.preferenceSuite)
        for invalid in ["", "../production", "org.clavune", "a/b", "a b", "ä", String(repeating: "x", count: 33)] {
            XCTAssertThrowsError(try AppLaunchConfiguration.parse(environment: ["CLAVUNE_QA_PROFILE": invalid]))
        }
        let valid = try AppLaunchConfiguration.parse(environment: ["CLAVUNE_QA_PROFILE": "window-QA-123"])
        XCTAssertEqual(valid.preferenceSuite, "org.clavune.DevelopmentQA.window-QA-123")
    }
    func testQAReadDoesNotFallBackToRegistrationAndWriteStaysInItsDomain() throws {
        let profile = "fixture-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20))
        let config = try AppLaunchConfiguration.parse(environment: ["CLAVUNE_QA_PROFILE": profile])
        let preferences = try config.makePreferences()
        let defaults = try XCTUnwrap(preferences.defaults)
        let suite = try XCTUnwrap(config.preferenceSuite)
        // Registration defaults can be visible to other UserDefaults suites in
        // this process. Removing the persistent QA suite does not undo register().
        let registration = defaults.volatileDomain(forName: UserDefaults.registrationDomain)
        defer {
            defaults.removePersistentDomain(forName: suite)
            defaults.removeVolatileDomain(forName: UserDefaults.registrationDomain)
            defaults.setVolatileDomain(registration, forName: UserDefaults.registrationDomain)
        }
        defaults.register(defaults: ["uiLanguage": "de", "selectedModelSHA256": "not-a-QA-selection"])
        XCTAssertNil(preferences.string(forKey: "uiLanguage"))
        XCTAssertNil(preferences.string(forKey: "selectedModelSHA256"))
        preferences.set("en", forKey: "uiLanguage")
        XCTAssertEqual(defaults.persistentDomain(forName: suite)?["uiLanguage"] as? String, "en")
        XCTAssertEqual(try config.makePreferences().string(forKey: "uiLanguage"), "en")
    }
    @MainActor func testQACoordinatorPersistsUIWithoutModelImportRestoreOrRecording() throws {
        let profile = "fixture-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20))
        let config = try AppLaunchConfiguration.parse(environment: ["CLAVUNE_QA_PROFILE": profile])
        let preferences = try config.makePreferences()
        let defaults = try XCTUnwrap(preferences.defaults)
        let suite = try XCTUnwrap(config.preferenceSuite)
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.set(String(repeating: "a", count: 64), forKey: "selectedModelSHA256")
        let fixture = try CoordinatorFixture(preferences: defaults, launchConfiguration: config)
        XCTAssertTrue(fixture.coordinator.isPresentationQA)
        XCTAssertNotNil(fixture.coordinator.model, "Fixture deliberately supplies a model to test the QA gate")
        XCTAssertFalse(fixture.coordinator.canStart)
        fixture.coordinator.start()
        fixture.coordinator.importModel()
        fixture.coordinator.restoreManagedModel()
        let withoutModel = try CoordinatorFixture(preferences: defaults,
            launchConfiguration: config, modelSelectionEnabled: false)
        withoutModel.coordinator.restoreManagedModel()
        XCTAssertNil(withoutModel.coordinator.model)
        XCTAssertFalse(withoutModel.coordinator.operationPending,
                       "QA must reject restoration before admitting a hashing task")
        XCTAssertFalse(fixture.coordinator.operationPending)
        XCTAssertEqual(fixture.pickerCalls, 0)
        XCTAssertEqual(fixture.permissionCalls, 0)
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
        XCTAssertEqual(fixture.inference.counts.value.loads, 0)
        fixture.coordinator.uiLanguage = .german
        fixture.coordinator.menuBarEnabled = false
        let reopened = try CoordinatorFixture(preferences: defaults, launchConfiguration: config)
        XCTAssertEqual(reopened.coordinator.uiLanguage, .german)
        XCTAssertFalse(reopened.coordinator.menuBarEnabled)
        XCTAssertEqual(preferences.string(forKey: "selectedModelSHA256"), String(repeating: "a", count: 64))
    }
}
