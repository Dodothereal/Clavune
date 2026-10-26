import XCTest
@testable import ClavuneCore

/// This fixture exercises only the in-memory callback latch. It never creates
/// an AX observer, reads a real app, requests permission, or mutates a target.
final class AXOneShotObservationLatchTests: XCTestCase {
    func testUnarmedLeaseIsUnavailableAndRevocationCannotHeal() {
        let latch = AXOneShotObservationLatch(epoch: 49)
        XCTAssertNil(latch.currentEpoch())
        XCTAssertTrue(latch.arm())
        XCTAssertEqual(latch.currentEpoch(), 49)
        latch.revoke() // any focus/selection/value/lifecycle callback
        XCTAssertNil(latch.currentEpoch())
        XCTAssertFalse(latch.arm()) // observed A -> B -> A remains revoked
        XCTAssertNil(latch.currentEpoch())
    }

    func testRevokedLatchCannotArmAfterSyntheticRegistrationFailure() {
        let latch = AXOneShotObservationLatch(epoch: 61)
        latch.revoke() // registration rollback first revokes
        XCTAssertFalse(latch.arm())
        XCTAssertNil(latch.currentEpoch())
    }
}
