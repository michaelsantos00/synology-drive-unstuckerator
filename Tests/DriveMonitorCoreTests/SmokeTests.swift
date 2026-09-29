import Testing
@testable import DriveMonitorCore

@Test func contractsExposeThePermanentFailureCode() {
    let state = FileProviderItemState(
        isDownloaded: true,
        isUploaded: false,
        isUploading: true,
        uploadingErrorDomain: "NSFileProviderErrorDomain",
        uploadingErrorCode: -2005
    )
    let parsed = EvaluationParseResult.item(state)
    guard case .item(let item) = parsed else {
        Issue.record("Expected an item parse result")
        return
    }
    #expect(item.uploadingErrorCode == -2005)
    #expect(FindingDisposition.actionable.rawValue == "actionable")
}
