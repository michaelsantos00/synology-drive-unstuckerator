import Foundation
import Testing
@testable import DriveMonitorCore

@Suite struct RetryNamingTests {
    @Test func testTimestampedSiblingName() {
        let name = RetryNaming.fileName(
            stem: "EDUC - E56 - 07 Episode",
            extension: "mp4",
            now: Date(timeIntervalSince1970: 1_790_196_300),
            takenNames: [],
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        #expect(name == "EDUC - E56 - 07 Episode.__requeued-20260923-204500.mp4")
    }

    @Test func testCollisionAppendsLowercaseHexSuffix() {
        let taken = "EDUC - E56 - 07 Episode.__requeued-20260923-204500.mp4"
        let name = RetryNaming.fileName(
            stem: "EDUC - E56 - 07 Episode",
            extension: ".mp4",
            now: Date(timeIntervalSince1970: 1_790_196_300),
            takenNames: [taken],
            randomSuffix: "AB12CD34ZZ",
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        #expect(name == "EDUC - E56 - 07 Episode.__requeued-20260923-204500-ab12cd34.mp4")
        #expect(name.contains(".__requeued-"))
    }
}
