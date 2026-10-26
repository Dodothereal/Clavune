import Foundation

/// Compares transcript drafts by their preserved UTF-8 representation.
/// Swift String equality intentionally treats canonically equivalent text as equal.
enum TranscriptTextIdentity {
    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }
}
