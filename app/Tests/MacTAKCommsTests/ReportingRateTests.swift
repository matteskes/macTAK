// G3.4b: ReportingRate gives ATAK 5.5's intervals and stale times. The
// expected numbers are worked by hand from upstream's ReportingRate.java
// (ms): Dynamic's stale is rate × 2 + 15000 for both streams, Constant's is
// rate × 4 + 15000 (unreliable) and rate × 2 + 15000 (reliable).

import XCTest
@testable import MacTAKComms

final class ReportingRateTests: XCTestCase {
    private let start: Int64 = 1_000_000
    private let mph = 0.44704

    private func report(_ unreliable: Int, _ reliable: Int) -> [ReportingRate.Report] {
        [.init(staleMillis: unreliable, stream: .unreliable), .init(staleMillis: reliable, stream: .reliable)]
    }

    /// The ticks, one a second from `start` to `start + seconds`, that
    /// reported on `stream`, in seconds from start.
    private func reportTimes(_ rate: inout ReportingRate, seconds: Int, speed: Double,
                             stream: ReportingRate.Stream) -> [Int] {
        (0...seconds).filter { s in
            rate.tick(now: start + Int64(s) * 1000, altitude: nil, speed: speed).contains { $0.stream == stream }
        }
    }

    func testDynamicStationaryIs30And180Seconds() {
        var rate = ReportingRate()
        XCTAssertEqual(rate.tick(now: start, altitude: nil, speed: 0), report(75_000, 375_000))
        XCTAssertEqual(rate.tick(now: start + 1000, altitude: nil, speed: 0), [])
        var r = ReportingRate()
        XCTAssertEqual(reportTimes(&r, seconds: 200, speed: 0, stream: .unreliable), [0, 30, 60, 90, 120, 150, 180])
        r = ReportingRate()
        XCTAssertEqual(reportTimes(&r, seconds: 200, speed: 0, stream: .reliable), [0, 180])
    }

    func testDynamicUnknownSpeedIsStationary() {
        var rate = ReportingRate()
        XCTAssertEqual(rate.tick(now: start, altitude: nil, speed: .nan), report(75_000, 375_000))
    }

    func testDynamicAtThirtyMphAndOverIsTwoSeconds() {
        for speed in [30 * mph, 60 * mph] {
            var rate = ReportingRate()
            _ = rate.tick(now: start, altitude: nil, speed: speed)   // the first tick is a speed change
            XCTAssertEqual(rate.tick(now: start + 2000, altitude: nil, speed: speed), report(19_000, 19_000))
            XCTAssertEqual(rate.tick(now: start + 3000, altitude: nil, speed: speed), [])
        }
    }

    func testDynamicBetweenIsUpstreamsStraightLine() {
        // halfway between 1 and 30 mph: scaled 50.447 %, 20000 - 9080.47 → 10920 ms
        let speed = (ReportingRate.minSpeed + ReportingRate.maxSpeed) / 2
        var rate = ReportingRate()
        rate.reportAsap()   // put both streams' last report at start
        _ = rate.tick(now: start, altitude: nil, speed: speed)
        XCTAssertEqual(rate.tick(now: start + 1000, altitude: nil, speed: speed).count, 2,
                       "upstream's quirk: an early ASAP leaves stale 0, so the next tick reports too")
        XCTAssertEqual(rate.tick(now: start + 11_000, altitude: nil, speed: speed), [])
        XCTAssertEqual(rate.tick(now: start + 11_920, altitude: nil, speed: speed), report(36_840, 36_840))
    }

    func testConstantIsThreeAndFifteenSeconds() {
        var r = ReportingRate(.init { $0.strategy = .constant })
        XCTAssertEqual(r.tick(now: start, altitude: nil, speed: 0), report(27_000, 45_000))
        r = ReportingRate(.init { $0.strategy = .constant })
        XCTAssertEqual(reportTimes(&r, seconds: 30, speed: 0, stream: .unreliable), [0, 3, 6, 9, 12, 15, 18, 21, 24, 27, 30])
        r = ReportingRate(.init { $0.strategy = .constant })
        XCTAssertEqual(reportTimes(&r, seconds: 30, speed: 0, stream: .reliable), [0, 15, 30])
    }

    func testReportsEarlyWhenTheLastStaleIsTenSecondsAway() {
        // Constant 3 s: the unreliable stale is 3000*4+15000 = 27 s. Raising
        // the rate to 60 s then leaves that stale: 10 s before it runs out
        // (17 s after the last report) the next one goes, not at 60 s.
        var rate = ReportingRate(.every(seconds: 3))
        XCTAssertEqual(rate.tick(now: start, altitude: nil, speed: 0).count, 2)
        rate.settings.constantUnreliable = 60
        rate.settings.constantReliable = 60
        let times = (1...20).filter { s in
            rate.tick(now: start + Int64(s) * 1000, altitude: nil, speed: 0).contains { $0.stream == .unreliable }
        }
        XCTAssertEqual(times, [17])
    }

    func testASpeedChangeOverSevenMphReportsBothAtOnce() {
        var rate = ReportingRate()
        _ = rate.tick(now: start, altitude: nil, speed: 0)
        XCTAssertEqual(rate.tick(now: start + 1000, altitude: nil, speed: 6 * mph), [], "6 mph is no change")
        XCTAssertEqual(rate.tick(now: start + 2000, altitude: nil, speed: 8 * mph), report(75_000, 375_000),
                       "8 mph is: both report, with the last stale times")
    }

    func testAnAltitudeChangeOverFiftyMetresReportsBothAtOnce() {
        var rate = ReportingRate()
        _ = rate.tick(now: start, altitude: 100, speed: 0)
        XCTAssertEqual(rate.tick(now: start + 1000, altitude: 149, speed: 0), [])
        XCTAssertEqual(rate.tick(now: start + 2000, altitude: 151, speed: 0).count, 2)
        XCTAssertEqual(rate.tick(now: start + 3000, altitude: nil, speed: 0), [], "an unknown altitude is no change")
    }

    func testReportAsapReportsBothOnTheNextTick() {
        var rate = ReportingRate()
        XCTAssertEqual(rate.tick(now: start, altitude: nil, speed: 0).count, 2)
        rate.reportAsap()
        XCTAssertEqual(rate.tick(now: start + 1000, altitude: nil, speed: 0), report(75_000, 375_000))
        XCTAssertEqual(rate.tick(now: start + 2000, altitude: nil, speed: 0), [])
    }

    func testAsapBeforeAnyReportUsesConstantsStale() {
        var rate = ReportingRate()
        rate.reportAsap()
        XCTAssertEqual(rate.tick(now: start, altitude: nil, speed: 0), report(27_000, 45_000))
    }
}

private extension ReportingRate.Settings {
    init(_ change: (inout Self) -> Void) {
        self.init()
        change(&self)
    }
}
