import Foundation

/// Temporary internal identity. Public naming clearance and an approved rename are pending.
/// Core audio, decoding, and safety behavior do not depend on the display name.
enum ProductIdentity {
    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Clavune"
    }
    static var modelDirectory: String {
        (Bundle.main.object(forInfoDictionaryKey: "ProductStorageDirectory") as? String ?? displayName) + "/Models"
    }
}
