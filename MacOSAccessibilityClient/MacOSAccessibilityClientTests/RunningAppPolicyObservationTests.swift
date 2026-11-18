import AppKit
import XCTest
@testable import MacOSAccessibilityClient

final class RunningAppPolicyObservationTests: XCTestCase {
    func testRetainsApplicationUntilObservationIsRemoved() throws {
        weak var application: NSRunningApplication?
        var observation: RunningAppPolicyObservation?

        try autoreleasepool {
            let app = try XCTUnwrap(NSRunningApplication(processIdentifier: ProcessInfo.processInfo.processIdentifier))
            application = app
            observation = RunningAppPolicyObservation(app) {}
        }

        // The caller has released its reference. Only the observation should own this instance.
        XCTAssertNotNil(application)
        withExtendedLifetime(observation) {}
        autoreleasepool { observation = nil }
        XCTAssertNil(application, "Removing the observation must also release its application.")
    }

    func testStopsDeliveringChangesAfterObservationIsRemoved() throws {
        let application = try XCTUnwrap(NSRunningApplication(processIdentifier: ProcessInfo.processInfo.processIdentifier))
        let changes = ChangeCounter()
        var observation: RunningAppPolicyObservation? = RunningAppPolicyObservation(application) {
            changes.increment()
        }

        application.willChangeValue(forKey: "activationPolicy")
        application.didChangeValue(forKey: "activationPolicy")
        XCTAssertEqual(changes.value, 1)

        withExtendedLifetime(observation) {}
        observation = nil
        application.willChangeValue(forKey: "activationPolicy")
        application.didChangeValue(forKey: "activationPolicy")
        XCTAssertEqual(changes.value, 1, "Released observations must not receive further notifications.")
    }
}

private final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}
