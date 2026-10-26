import Foundation

/// Explicit isolated development QA; functional simulation needs its second opt-in.
/// Missing opt-in means production;
/// malformed opt-in fails closed instead of falling back to production preferences.
struct AppLaunchConfiguration {
    enum ConfigurationError: Error { case invalidQAProfile, unavailableQASuite, invalidFunctionalQA, invalidNativePanelQA }
    // This identity exists only in the isolated comparison build. A native
    // computer-use launch does not carry shell environment opt-ins, so this
    // particular bundle must never fall through to production preferences or
    // hardware boundaries. The production bundle has a different identifier.
    private static let stableComparisonBundleID = "org.clavune.observatory.qa.20261023.adaptive.main.v3"
    private static let stableComparisonProfile = "adaptive-main-v3-20261023"
    static var isStableComparisonBundle: Bool {
        Bundle.main.bundleIdentifier == stableComparisonBundleID
    }
    static let production = AppLaunchConfiguration(qaProfile: nil, functional: false)
    let qaProfile: String?
    let isFunctionalQA: Bool
    let isNativePanelQA: Bool
    private init(qaProfile: String?, functional: Bool, nativePanels: Bool = false) {
        self.qaProfile = qaProfile; self.isFunctionalQA = functional; self.isNativePanelQA = nativePanels
    }
    var isQA: Bool { qaProfile != nil }
    var preferenceSuite: String? {
        guard !isNativePanelQA else { return nil }
        return qaProfile.map { "org.clavune.DevelopmentQA." + $0 }
    }

    static func parse(environment: [String: String],
                      bundleIdentifier: String? = Bundle.main.bundleIdentifier) throws -> Self {
        let functional = environment["CLAVUNE_QA_FUNCTIONAL"]
        let nativePanels = environment["CLAVUNE_QA_NATIVE_PANELS"]
        guard functional == nil || functional == "synthetic-v1" else { throw ConfigurationError.invalidFunctionalQA }
        guard nativePanels == nil || nativePanels == "synthetic-v1" else {
            throw ConfigurationError.invalidNativePanelQA
        }
        if bundleIdentifier == stableComparisonBundleID {
            // An inconsistent explicit profile fails closed; omission is safe
            // because this signed QA bundle itself supplies the fixed profile.
            if let profile = environment["CLAVUNE_QA_PROFILE"], profile != stableComparisonProfile {
                throw ConfigurationError.invalidQAProfile
            }
            return AppLaunchConfiguration(qaProfile: stableComparisonProfile, functional: true,
                                          nativePanels: nativePanels != nil)
        }
        guard let profile = environment["CLAVUNE_QA_PROFILE"] else {
            guard functional == nil else { throw ConfigurationError.invalidFunctionalQA }
            guard nativePanels == nil else { throw ConfigurationError.invalidNativePanelQA }
            return .production
        }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard (1...32).contains(profile.count), profile.allSatisfy({ allowed.contains($0) }) else {
            throw ConfigurationError.invalidQAProfile
        }
        let configuration = AppLaunchConfiguration(qaProfile: profile, functional: functional != nil,
                                                   nativePanels: nativePanels != nil)
        guard nativePanels == nil || configuration.isFunctionalQA else {
            throw ConfigurationError.invalidNativePanelQA
        }
        return configuration
    }
    func makePreferences() throws -> AppPreferences {
        if isNativePanelQA {
            guard let qaProfile else { throw ConfigurationError.invalidQAProfile }
            return AppPreferences(ephemeralProfile: qaProfile)
        }
        if let suite = preferenceSuite {
            guard let defaults = UserDefaults(suiteName: suite) else {
                throw ConfigurationError.unavailableQASuite
            }
            return AppPreferences(defaults: defaults, isolatedSuite: suite)
        }
        return AppPreferences(defaults: .standard)
    }
}

/// QA reads only its exact persistent domain: no argument, global, registration or
/// production-domain fallback. Writes target the selected UserDefaults owner only.
struct AppPreferences {
    let defaults: UserDefaults?
    var isolatedSuite: String? = nil
    private let ephemeral: EphemeralPreferenceDomain?
    init(defaults: UserDefaults, isolatedSuite: String? = nil) {
        self.defaults = defaults; self.isolatedSuite = isolatedSuite; ephemeral = nil
    }
    fileprivate init(ephemeralProfile: String) {
        defaults = nil; isolatedSuite = nil; ephemeral = EphemeralPreferenceDomain(profile: ephemeralProfile)
    }
    var isEphemeral: Bool { ephemeral != nil }
    func object(forKey key: String) -> Any? {
        if let ephemeral { return ephemeral.object(forKey: key) }
        guard let defaults else { return nil }
        if let isolatedSuite { return defaults.persistentDomain(forName: isolatedSuite)?[key] }
        return defaults.object(forKey: key)
    }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func set(_ value: Any?, forKey key: String) {
        if let ephemeral { ephemeral.set(value, forKey: key) }
        else { defaults?.set(value, forKey: key) }
    }
}

private final class EphemeralPreferenceDomain: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    let profile: String
    init(profile: String) { self.profile = profile }
    func object(forKey key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }
    func set(_ value: Any?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }
}
