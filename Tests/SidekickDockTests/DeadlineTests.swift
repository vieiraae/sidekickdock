import XCTest
@testable import SidekickDock

final class DeadlineTests: XCTestCase {

    func testReturnsValueWhenOperationFinishesInTime() async throws {
        let value = try await withDeadline(seconds: 2) { 7 }
        XCTAssertEqual(value, 7)
    }

    func testGivesUpOnAnOperationThatNeverReturns() async {
        let started = Date()
        do {
            _ = try await withDeadline(seconds: 0.2) {
                try await Task.sleep(for: .seconds(30))
                return 0
            }
            XCTFail("expected the deadline to fire")
        } catch {
            XCTAssertTrue(error is DeadlineExceeded)
        }
        // The point of the deadline is that the caller is released promptly, not eventually.
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testPropagatesTheOperationsOwnError() async {
        struct Boom: Error {}
        do {
            _ = try await withDeadline(seconds: 5) { throw Boom() }
            XCTFail("expected the operation's error")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }
}
