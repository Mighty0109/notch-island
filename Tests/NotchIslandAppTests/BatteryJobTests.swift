import XCTest
@testable import NotchIsland
import NotchIslandCore

/// 배터리 진행 링은 충전 여부와 무관하게 항상 뜬다(배터리 없는 맥만 제외). 저전력(충전 중 아님 + 20% 이하)은 경고.
final class BatteryJobTests: XCTestCase {
    func testChargingShowsChargeLabelWithoutWarning() {
        let j = JobInfo.battery(BatteryInfo(percent: 85, isCharging: true, onACPower: true))
        XCTAssertEqual(j?.short, "충전")
        XCTAssertEqual(j?.label, "배터리 충전")
        XCTAssertEqual(j?.tag, "charge")
        XCTAssertEqual(j?.low, false)
    }

    func testDischargingShowsBatteryLabelWithoutWarning() {
        let j = JobInfo.battery(BatteryInfo(percent: 85, isCharging: false, onACPower: false))
        XCTAssertEqual(j?.short, "배터리")
        XCTAssertEqual(j?.tag, "battery")
        XCTAssertEqual(j?.percent, 85)
        XCTAssertEqual(j?.low, false)
    }

    func testPluggedInButNotChargingIsDistinguishedAndNotCharge() {
        let j = JobInfo.battery(BatteryInfo(percent: 100, isCharging: false, onACPower: true))
        XCTAssertEqual(j?.short, "배터리")
        XCTAssertEqual(j?.label, "배터리 · 전원")
        XCTAssertEqual(j?.tag, "battery")
    }

    func testLowBatteryWarnsAtTwentyPercentAndBelowOnly() {
        XCTAssertEqual(JobInfo.battery(BatteryInfo(percent: 20, isCharging: false, onACPower: false))?.low, true)
        XCTAssertEqual(JobInfo.battery(BatteryInfo(percent: 21, isCharging: false, onACPower: false))?.low, false)
    }

    func testChargingLowDoesNotWarn() {
        XCTAssertEqual(JobInfo.battery(BatteryInfo(percent: 15, isCharging: true, onACPower: true))?.low, false)
    }

    func testNoBatteryMeansNoJob() {
        XCTAssertNil(JobInfo.battery(nil))
    }
}
