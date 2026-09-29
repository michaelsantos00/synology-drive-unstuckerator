import Foundation
import Testing
@testable import DriveMonitorCore

@Suite struct CandidateRulesTests {
    @Test func testEligibleEpisodeName() {
        let decision = CandidateRules.evaluate(
            name: "EDUC - E56 - 07 Episode.mp4",
            isHidden: false,
            isRegularFile: true,
            byteSize: 2_613_855_666,
            age: 400,
            extensions: ["mp4"]
        )
        #expect(decision == .accept)
    }

    @Test func testUppercaseExtension() {
        let decision = CandidateRules.evaluate(
            name: "take.MP4",
            isHidden: false,
            isRegularFile: true,
            byteSize: 10,
            age: 400,
            extensions: ["mp4"]
        )
        #expect(decision == .accept)
    }

    @Test func testMovStaysExcluded() {
        #expect(rejects("episode.mov"))
    }

    @Test func testSegmentTemporaryAndRequeueNames() {
        #expect(rejects("clip_segment_0001.mp4"))
        #expect(rejects("Episode.__requeued-20260923-142500.mp4"))
        #expect(rejects("notes.mp4.tmp"))
        #expect(rejects("export.part"))
        #expect(rejects("Episode (conflicted copy).mp4".replacingOccurrences(of: "(conflicted copy)", with: " conflicted copy")))
        #expect(rejects("Episode (conflict 1).mp4"))
    }

    @Test func testHiddenAndUnstableFiles() {
        let hidden = CandidateRules.evaluate(
            name: ".hidden.mp4",
            isHidden: true,
            isRegularFile: true,
            byteSize: 10,
            age: 400,
            extensions: ["mp4"]
        )
        guard case .reject = hidden else {
            Issue.record("Hidden files are rejected")
            return
        }
        let fresh = CandidateRules.evaluate(
            name: "fresh.mp4",
            isHidden: false,
            isRegularFile: true,
            byteSize: 10,
            age: 30,
            extensions: ["mp4"]
        )
        guard case .reject = fresh else {
            Issue.record("Files younger than five minutes are rejected")
            return
        }
        let empty = CandidateRules.evaluate(
            name: "empty.mp4",
            isHidden: false,
            isRegularFile: true,
            byteSize: 0,
            age: 400,
            extensions: ["mp4"]
        )
        guard case .reject = empty else {
            Issue.record("Empty files are rejected")
            return
        }
    }

    private func rejects(_ name: String) -> Bool {
        guard case .reject = CandidateRules.evaluate(
            name: name,
            isHidden: false,
            isRegularFile: true,
            byteSize: 10,
            age: 400,
            extensions: ["mp4"]
        ) else {
            return false
        }
        return true
    }
}
