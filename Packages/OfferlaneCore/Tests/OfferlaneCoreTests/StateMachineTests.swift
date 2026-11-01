import XCTest
@testable import OfferlaneCore

final class StateMachineTests: XCTestCase {
    /// Every one of the 17×17 pairs: `check` throws exactly when the move isn't in the table.
    func testEveryPairMatchesTheTable() {
        var legal = 0, illegal = 0
        for a in JobStatus.allCases {
            for b in JobStatus.allCases {
                let ok = StateMachine.allowed[a]?.contains(b) ?? false
                if ok { XCTAssertNoThrow(try StateMachine.check(a, to: b), "\(a)→\(b)"); legal += 1 }
                else { XCTAssertThrowsError(try StateMachine.check(a, to: b), "\(a)→\(b)"); illegal += 1 }
            }
        }
        XCTAssertEqual(legal + illegal, 17 * 17)
        XCTAssertGreaterThan(illegal, legal)
    }

    func testHumanGatesCannotBeSkipped() {
        // Nothing is tailored, applied or submitted without passing the user's gates.
        for (a, b) in [(JobStatus.found, JobStatus.review), (.found, .ready), (.found, .applying), (.found, .applied),
                       (.tailoring, .ready), (.tailoring, .applying), (.review, .applying), (.review, .applied),
                       (.ready, .applied), (.ready, .prefilled), (.account, .prefilled), (.declined, .review), (.applied, .found)] {
            XCTAssertFalse(StateMachine.canMove(a, to: b), "\(a)→\(b) must be illegal")
        }
    }

    func testWorkflowHappyPathIsLegal() throws {
        let path: [JobStatus] = [.found, .tailoring, .review, .ready, .applying, .account, .applying, .needsYou, .applying, .prefilled, .applied,
                                 .acknowledged, .interview, .offer]
        for (a, b) in zip(path, path.dropFirst()) { try StateMachine.check(a, to: b) }
    }

    func testTrackedStatusesCanBeDraggedAndRejected() {
        for a in JobStatus.tracked {
            for b in JobStatus.tracked where a != b { XCTAssertTrue(StateMachine.canMove(a, to: b)) }
            XCTAssertTrue(StateMachine.canMove(a, to: .rejected)); XCTAssertTrue(StateMachine.canMove(a, to: .withdrawn))
            XCTAssertFalse(StateMachine.canMove(a, to: .found)); XCTAssertFalse(StateMachine.canMove(a, to: a))
        }
    }

    func testLegacyDismissedMapsToDeclined() {
        XCTAssertEqual(JobStatus(legacy: "dismissed"), .declined)
        XCTAssertEqual(JobStatus(legacy: "needs_you"), .needsYou)
        XCTAssertNil(JobStatus(legacy: "shortlisted"))
    }
}
