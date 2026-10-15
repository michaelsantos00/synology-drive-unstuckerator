import Foundation
import Testing
@testable import DriveMonitorCore

@Suite struct RetryNamingTests {
    @Test func extensionlessRetryHasNoTrailingDotEvenOnCollision() {
        let date = Date(timeIntervalSince1970: 1_790_196_300)
        let base = "README.__requeued-20260923-204500"
        #expect(RetryNaming.fileName(stem: "README", extension: "", now: date, takenNames: [],
                                    timeZone: TimeZone(secondsFromGMT: 0)!) == base)
        #expect(RetryNaming.fileName(stem: "README", extension: "", now: date, takenNames: [base],
                                    randomSuffix: "ab12", timeZone: TimeZone(secondsFromGMT: 0)!) == base + "-ab12")
    }

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
