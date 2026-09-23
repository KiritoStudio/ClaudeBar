import XCTest
@testable import ClaudeBar

final class FiveHourAnchorTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func decide(
        enabled: Bool = true,
        running: Bool = false,
        fiveHour: UsageBucket?,
        lastAnchorAt: Date? = nil
    ) -> FiveHourAnchorDecision {
        FiveHourAnchorPolicy.decide(
            isEnabled: enabled,
            isRunning: running,
            fiveHour: fiveHour,
            lastAnchorAt: lastAnchorAt,
            now: now
        )
    }

    private var untouched: UsageBucket { UsageBucket(utilization: 0, resetsAt: nil) }

    func testAnchorsUntouchedWindow() {
        XCTAssertEqual(decide(fiveHour: untouched), .anchor)
    }

    func testAnchorsWindowWhoseResetTimeHasPassed() {
        let expired = UsageBucket(utilization: 40, resetsAt: iso(now.addingTimeInterval(-60)))
        XCTAssertEqual(decide(fiveHour: expired), .anchor)
    }

    func testSkipsStartedWindowEvenAtZeroPercent() {
        // One prompt rounds to 0%, so usage alone cannot tell an unstarted window from a started one.
        let started = UsageBucket(utilization: 0, resetsAt: iso(now.addingTimeInterval(3600)))
        XCTAssertEqual(decide(fiveHour: started), .skip(.windowAlreadyStarted))
    }

    func testSkipsWhenDisabledOrRunning() {
        XCTAssertEqual(decide(enabled: false, fiveHour: untouched), .skip(.disabled))
        XCTAssertEqual(decide(running: true, fiveHour: untouched), .skip(.alreadyRunning))
    }

    func testSkipsWhenWindowMissing() {
        XCTAssertEqual(decide(fiveHour: nil), .skip(.noFiveHourWindow))
    }

    func testSkipsWhenWindowStartIsUnknown() {
        XCTAssertEqual(decide(fiveHour: UsageBucket(utilization: nil, resetsAt: nil)), .skip(.unknownWindowStart))
        XCTAssertEqual(decide(fiveHour: UsageBucket(utilization: 0, resetsAt: "garbage")), .skip(.unknownWindowStart))
    }

    func testCooldownHoldsForOneWindowLength() {
        let recent = now.addingTimeInterval(-FiveHourAnchor.windowLength + 60)
        XCTAssertEqual(decide(fiveHour: untouched, lastAnchorAt: recent), .skip(.cooldown))

        let old = now.addingTimeInterval(-FiveHourAnchor.windowLength)
        XCTAssertEqual(decide(fiveHour: untouched, lastAnchorAt: old), .anchor)
    }
}
