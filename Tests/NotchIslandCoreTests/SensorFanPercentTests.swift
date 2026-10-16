import XCTest
@testable import NotchIslandCore

final class SensorFanPercentTests: XCTestCase {
    func testAveragesIndividualRatiosRatherThanRPMs() {
        let v = SensorValues(fanRPMs: [2000, 6000], fanMaxRPMs: [4000, 8000])
        XCTAssertEqual(v.fanPercents, [50, 75])
        XCTAssertEqual(v.fanPercent, 63)
    }

    func testRoundsAfterAveragingAndCapsEachFanBeforeAveraging() {
        XCTAssertEqual(SensorValues(fanRPMs: [494, 496], fanMaxRPMs: [1000, 1000]).fanPercent, 50)
        XCTAssertEqual(SensorValues(fanRPMs: [12000, 2000], fanMaxRPMs: [8000, 8000]).fanPercent, 63)
        XCTAssertEqual(SensorValues(fanRPMs: [995], fanMaxRPMs: [1000]).fanPercent, 100)
    }

    func testMissingMaximumOnlyExcludesThatFan() {
        let v = SensorValues(fanRPMs: [4000, 6000], fanMaxRPMs: [nil, 8000])
        XCTAssertEqual(v.fanPercents, [nil, 75])
        XCTAssertEqual(v.fanPercent, 75)
        XCTAssertEqual(SensorValues(fanRPMs: [2000, 6000], fanMaxRPMs: [4000]).fanPercent, 50)
    }

    func testNoUsableMaximumOrNoFansReturnsNil() {
        for maxima: [Double?] in [[], [nil, nil], [0, -1], [.nan, .infinity]] {
            XCTAssertNil(SensorValues(fanRPMs: [3000, 4000], fanMaxRPMs: maxima).fanPercent)
        }
        XCTAssertNil(SensorValues().fanPercent)
        XCTAssertNil(SensorValues(fanRPMs: [], fanMaxRPMs: [8000]).fanPercent)
    }

    func testStoppedFansAndInvalidCurrentRPM() {
        XCTAssertEqual(SensorValues(fanRPMs: [0, 0], fanMaxRPMs: [8000, 8000]).fanPercent, 0)
        XCTAssertEqual(SensorValues(fanRPMs: [0, 4000], fanMaxRPMs: [8000, 8000]).fanPercent, 25)
        XCTAssertNil(SensorValues(fanRPMs: [-1, .nan, .infinity], fanMaxRPMs: [8000, 8000, 8000]).fanPercent)
    }
}
