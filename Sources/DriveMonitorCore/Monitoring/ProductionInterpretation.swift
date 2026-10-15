import Foundation

public enum ProductionInterpretation {
    public static let standard = EvaluationInterpreting(
        parse: { FileProviderParser.parse($0) },
        classify: { EvaluationClassification.classify($0) },
        isActionablePermanentFailure: { FileProviderParser.isActionablePermanentFailure($0) },
        candidate: { path, _ in
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent
            return CandidateRules.evaluate(
                name: name,
                isHidden: name.hasPrefix("."),
                isRegularFile: true,
                byteSize: 1,
                age: CandidateRules.defaultMinimumAge,
                // The engine applies each folder's type selection separately; this policy checks names.
                extensions: [FileFormatCatalog.allFilesMarker]
            )
        },
        confirm: { previous, previousObservation, latest, baselineCompleted in
            ConfirmationPolicy.nextState(
                previous: previous,
                previousObservation: previousObservation,
                latest: latest,
                baselineCompleted: baselineCompleted
            )
        }
    )
}
