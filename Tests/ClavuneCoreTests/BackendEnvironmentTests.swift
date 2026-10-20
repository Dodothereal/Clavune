import XCTest
import NativeBridge
import ClavuneCore

final class BackendEnvironmentTests: XCTestCase {
    func testBackendArchiveFingerprintIsLinked() {
        let fingerprint = String(cString: ow_backend_fingerprint())
        XCTAssertEqual(SessionMetrics(session: UUID(), requestedStart: 0).backendFingerprint, fingerprint)
        XCTAssertEqual(fingerprint.count, 64)
        XCTAssertTrue(fingerprint.allSatisfy { $0.isHexDigit })
    }
    func testLinkedBackendContainsStateOwnershipCorrectnessPatch() {
        XCTAssertEqual(ow_backend_state_ownership_patch_revision(), 1)
    }
    func testOnlyUnsetOptionalEncoderEnvironmentIsAllowed() {
        XCTAssertEqual(ow_backend_environment_allowed(nil, nil), 1)
        "unapproved-encoder".withCString { encoder in
            XCTAssertEqual(ow_backend_environment_allowed(encoder, nil), 0)
            "unapproved-library.dylib".withCString { library in
                XCTAssertEqual(ow_backend_environment_allowed(nil, library), 0)
                XCTAssertEqual(ow_backend_environment_allowed(encoder, library), 0)
            }
        }
    }

    func testEmptyOptionalEnvironmentValuesStillFailClosed() {
        "".withCString { presentButEmpty in
            XCTAssertEqual(ow_backend_environment_allowed(presentButEmpty, nil), 0)
            XCTAssertEqual(ow_backend_environment_allowed(nil, presentButEmpty), 0)
            XCTAssertEqual(ow_backend_environment_allowed(presentButEmpty, presentButEmpty), 0)
        }
    }
}
