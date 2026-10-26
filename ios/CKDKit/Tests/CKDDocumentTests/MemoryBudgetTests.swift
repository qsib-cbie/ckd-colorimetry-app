import CKDDocument
import Foundation
import XCTest

final class MemoryBudgetTests: XCTestCase {
    func testEstimatesFollowTheMeasuredCostPerPixel() throws {
        let megabyte = 1_048_576
        let proRAW = try MemoryBudget.required(for: Paths.fixtures.appendingPathComponent("iPhoneRAW.DNG"), holdsImage: false)
        XCTAssertEqual(proRAW, 4032 * 3024 * 19 + 150 * megabyte)
        let canon = try MemoryBudget.required(for: Paths.fixtures.appendingPathComponent("SampleImg1.CR2"), holdsImage: false)
        XCTAssertGreaterThan(canon, 20_000_000 * 13 + 150 * megabyte)
        XCTAssertLessThan(canon, 21_000_000 * 13 + 150 * megabyte)
        XCTAssertEqual(MemoryBudget.required(pixels: 1_000_000, linear: true, holdsImage: true), 23_000_000 + 150 * megabyte)
        XCTAssertGreaterThan(MemoryBudget.required(pixels: 48_771_072, linear: true, holdsImage: false), 1_012 * megabyte,
                             "covers the 48.8 MP whole-app peak measured in the simulator")
    }

    func testRefusesOnlyWhenAKnownLimitIsTooLow() throws {
        XCTAssertNoThrow(try MemoryBudget.check(required: 500, available: 0))
        XCTAssertNoThrow(try MemoryBudget.check(required: 500, available: 500))
        XCTAssertThrowsError(try MemoryBudget.check(required: 300 * 1_048_576, available: 100 * 1_048_576)) { error in
            XCTAssertTrue(error.localizedDescription.hasPrefix("This image needs about 300 MB of memory to process, and this iPad or iPhone has about 100 MB free"),
                          error.localizedDescription)
        }
    }
}
