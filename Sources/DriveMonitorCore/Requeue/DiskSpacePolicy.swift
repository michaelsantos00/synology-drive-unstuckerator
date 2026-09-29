import Foundation

/// Refuses a publication on insufficient free space. That check cannot be turned off.
/// A validated same-volume clone needs only the configured reserve. Otherwise the
/// requirement is at least twice the source size and the source size plus the reserve.

public struct DiskAllowance: Equatable, Sendable {
    public var allowFullCopyFallback: Bool

    public init(allowFullCopyFallback: Bool) {
        self.allowFullCopyFallback = allowFullCopyFallback
    }
}

public enum DiskAssessment: Equatable, Sendable {
    case allowed(DiskAllowance)
    case blocked(RequeueBlockReason)
}

public struct DiskSpacePolicy: Equatable, Sendable {
    public static let gibibyte: Int64 = 1024 * 1024 * 1024
    public static let minimumReserve: Int64 = gibibyte

    public var warningThreshold: Int64
    public var reserve: Int64

    public init(warningThreshold: Int64 = 100 * DiskSpacePolicy.gibibyte, reserve: Int64 = 20 * DiskSpacePolicy.gibibyte) {
        self.warningThreshold = warningThreshold
        self.reserve = max(reserve, Self.minimumReserve)
    }

    public func shouldWarn(available: Int64) -> Bool {
        available < warningThreshold
    }

    public func assess(available: Int64, sourceSize: Int64, sameVolume: Bool, cloneValidated: Bool) -> DiskAssessment {
        if !sameVolume {
            return .blocked(.crossVolume)
        }
        let required = requiredBytes(sourceSize: sourceSize, cloneValidated: cloneValidated)
        if available < required {
            return .blocked(.insufficientSpace(available: available, required: required))
        }
        return .allowed(DiskAllowance(allowFullCopyFallback: !cloneValidated))
    }

    private func requiredBytes(sourceSize: Int64, cloneValidated: Bool) -> Int64 {
        if cloneValidated {
            return reserve
        }
        let doubled = sourceSize > Int64.max / 2 ? Int64.max : sourceSize * 2
        let copyFloor = sourceSize > Int64.max - reserve ? Int64.max : sourceSize + reserve
        return max(sourceSize, max(reserve, max(doubled, copyFloor)))
    }
}
