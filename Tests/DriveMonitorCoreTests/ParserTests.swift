import Foundation
import Testing
@testable import DriveMonitorCore

@Suite struct ParserTests {
    @Test func testPermanent2005GoldenFixture() throws {
        let output = try FixtureLoader.text("permanent-2005")
        let parsed = FileProviderParser.parse(output)
        guard case .item(let item) = parsed else {
            Issue.record("Expected an item, got \(parsed)")
            return
        }
        #expect(item.isUploaded == false)
        #expect(item.isUploading == true)
        #expect(item.isDownloaded == true)
        #expect(item.documentSize == 2_613_855_666)
        #expect(item.itemIdentifier == "974755024032807400")
        #expect(item.uploadingErrorDomain == "NSFileProviderErrorDomain")
        #expect(item.uploadingErrorCode == -2005)
        #expect(EvaluationClassification.classify(parsed) == .permanentFailure(domain: "NSFileProviderErrorDomain", code: -2005))
        #expect(FileProviderParser.isActionablePermanentFailure(item))
    }

    @Test func testUploadedWithoutError() {
        let parsed = FileProviderParser.parse(wrapper("isUploaded = 1;\n            isUploading = 0;"))
        #expect(EvaluationClassification.classify(parsed) == .uploaded)
    }

    @Test func testDictionaryUploadingErrorIsIncompatible() {
        let parsed = FileProviderParser.parse(wrapper("""
            isUploaded = 1;
            uploadingError = { domain = "NSFileProviderErrorDomain"; };
        """))
        guard case .incompatible = EvaluationClassification.classify(parsed) else {
            Issue.record("A dictionary uploadingError must not be treated as success")
            return
        }
    }

    @Test func testUploadingWithoutError() {
        let parsed = FileProviderParser.parse(wrapper("isUploaded = 0;\n            isUploading = 1;"))
        #expect(EvaluationClassification.classify(parsed) == .uploading)
    }

    @Test func testExcluded() {
        let parsed = FileProviderParser.parse(wrapper("""
            isExcludedFromSync = 1;
            isUploaded = 0;
            uploadingError = "Error Domain=NSFileProviderErrorDomain Code=-2005 \\"(null)\\"";
        """))
        #expect(EvaluationClassification.classify(parsed) == .excluded)
    }

    @Test func testPaused() {
        let parsed = FileProviderParser.parse(wrapper("""
            isSyncPaused = 1;
            isUploaded = 0;
            uploadingError = "Error Domain=NSFileProviderErrorDomain Code=-2005 \\"(null)\\"";
        """))
        #expect(EvaluationClassification.classify(parsed) == .syncPaused)
    }

    @Test func testMissingItem() {
        let parsed = FileProviderParser.parse("Couldn't find a file for the requested item")
        #expect(parsed == .missingItem)
        #expect(EvaluationClassification.classify(parsed) == .missingItem)
    }

    @Test func testUnknownFormat() {
        let parsed = FileProviderParser.parse("hello")
        guard case .incompatible = parsed else {
            Issue.record("Expected incompatible")
            return
        }
        guard case .incompatible = EvaluationClassification.classify(parsed) else {
            Issue.record("Expected incompatible classification")
            return
        }
    }

    @Test func testErrorProseWithoutNumericCode() {
        let parsed = FileProviderParser.parse(wrapper("""
            isUploaded = 0;
            uploadingError = "The operation could not be completed.";
        """))
        guard case .incompatible = parsed else {
            Issue.record("Expected incompatible, got \(parsed)")
            return
        }
    }

    @Test func testOtherNumericError() {
        let parsed = FileProviderParser.parse(wrapper("""
            isUploaded = 0;
            uploadingError = "Error Domain=NSFileProviderErrorDomain Code=-2001 \\"(null)\\"";
        """))
        guard case .item(let item) = parsed else {
            Issue.record("Expected item, got \(parsed)")
            return
        }
        #expect(item.uploadingErrorCode == -2001)
        guard case .incompatible = EvaluationClassification.classify(parsed) else {
            Issue.record("Other numeric errors are not permanent failures")
            return
        }
    }

    @Test func testQuotedIdentifier() {
        let parsed = FileProviderParser.parse(wrapper("""
            isUploaded = 1;
            itemIdentifier = "abc";
        """))
        guard case .item(let item) = parsed else {
            Issue.record("Expected item")
            return
        }
        #expect(item.itemIdentifier == "abc")
    }

    @Test func testActionsSectionIgnored() {
        let output = wrapper("isUploaded = 1;\n            isUploading = 0;") + """

        Actions:
        com.example.Action: Code=-2005 - YES
        """
        #expect(EvaluationClassification.classify(FileProviderParser.parse(output)) == .uploaded)
    }

    @Test func testMultipleItems() {
        let output = """
        Evaluating actions against {
            fileproviderItems = (
                {
                    isUploaded = 0;
                },
                {
                    isUploaded = 1;
                }
            );
        }
        """
        guard case .incompatible = FileProviderParser.parse(output) else {
            Issue.record("Expected incompatible")
            return
        }
    }

    @Test func testNotDownloadedIsNotActionable() {
        let parsed = FileProviderParser.parse(wrapper("""
            isDownloaded = 0;
            isUploaded = 0;
            isUploading = 1;
            uploadingError = "Error Domain=NSFileProviderErrorDomain Code=-2005 \\"(null)\\"";
        """))
        guard case .item(let item) = parsed else {
            Issue.record("Expected item, got \(parsed)")
            return
        }
        #expect(EvaluationClassification.classify(parsed) == .permanentFailure(domain: "NSFileProviderErrorDomain", code: -2005))
        #expect(!FileProviderParser.isActionablePermanentFailure(item))
    }
}

@Suite struct DumpSummaryParserTests {
    @Test func testReadableCount() {
        let parsed = DumpSummaryParser.parse("domain: com.synology.CloudStationUI.FileProvider/22\npermanent error count: 126\n")
        #expect(parsed == .count(126))
    }

    @Test func testObfuscatedDumpIsUnavailable() {
        let parsed = DumpSummaryParser.parse("domain: B{34}6 (i{9}e)\n")
        guard case .unavailable = parsed else {
            Issue.record("Expected unavailable")
            return
        }
    }
}

private func wrapper(_ body: String) -> String {
    """
    Evaluating actions against {
        fileproviderItems = (
                    {
            \(body)
        }
        );
    }
    """
}

enum FixtureLoader {
    static func text(_ name: String) throws -> String {
        let bundle = Bundle.module
        let candidates = [
            bundle.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures/FileProvider"),
            bundle.url(forResource: name, withExtension: "txt", subdirectory: "FileProvider"),
            bundle.resourceURL?.appendingPathComponent("Fixtures/FileProvider/\(name).txt"),
            bundle.resourceURL?.appendingPathComponent("FileProvider/\(name).txt")
        ]
        for url in candidates.compactMap({ $0 }) where FileManager.default.fileExists(atPath: url.path) {
            return try String(contentsOf: url, encoding: .utf8)
        }
        Issue.record("Missing fixture \(name). Bundle resources: \(bundle.resourceURL?.path ?? "none")")
        throw FixtureError.missing
    }
}

enum FixtureError: Error {
    case missing
}
