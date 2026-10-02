import Foundation

/// Limits children, diagnostic memory, and caller wait time. Timed-out read-only
/// children retain their slot until exit; repeated scans cannot accumulate them.
enum BoundedProcess {
    private static let slots = ProcessSlots()
    /// How long a check waits for a free slot when other checks fill all of them.
    static let admissionWait: Duration = .seconds(15)

    static func run(executable: URL, arguments: [String], timeout: TimeInterval,
                    outputLimit: Int = 1_048_576) async throws -> CommandResult {
        let key = ([executable.path] + arguments).joined(separator: "\0")
        try await slots.acquire(key, waitingUpTo: min(admissionWait, .seconds(timeout)))
        return try await withCheckedThrowingContinuation { continuation in
            let completion = ProcessCompletion(continuation)
            let deadline = DispatchWorkItem {
                completion.finish(.failure(MonitoringError.blocked(reason: "Read-only command timed out. Further checks are bounded until it exits.")))
            }
            completion.setDeadline(deadline)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
            DispatchQueue.global(qos: .utility).async {
                defer { slots.release(key) }
                do {
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = arguments
                    let stdout = Pipe(), stderr = Pipe()
                    process.standardOutput = stdout
                    process.standardError = stderr
                    try process.run()
                    let output = LimitedCapture(limit: outputLimit), errors = LimitedCapture(limit: outputLimit)
                    let group = DispatchGroup()
                    for (pipe, capture) in [(stdout, output), (stderr, errors)] {
                        group.enter()
                        DispatchQueue.global(qos: .utility).async {
                            defer { group.leave() }
                            while true {
                                let data = pipe.fileHandleForReading.availableData
                                if data.isEmpty { break }
                                capture.append(data)
                            }
                        }
                    }
                    process.waitUntilExit()
                    group.wait()
                    guard !output.exceeded, !errors.exceeded else {
                        throw MonitoringError.blocked(reason: "Read-only command output exceeds the diagnostic limit.")
                    }
                    guard let text = String(data: output.data, encoding: .utf8),
                          let errorText = String(data: errors.data, encoding: .utf8) else {
                        throw MonitoringError.blocked(reason: "Read-only command output is not valid UTF-8.")
                    }
                    completion.finish(.success(CommandResult(exitCode: process.terminationStatus, standardOutput: text, standardError: errorText)))
                } catch { completion.finish(.failure(error)) }
            }
        }
    }
}

private final class ProcessSlots: @unchecked Sendable {
    private enum Admission { case admitted, duplicate, full }
    private let lock = NSLock()
    private var active: Set<String> = []

    /// The same command already running fails at once: waiting would only repeat it. When other
    /// checks fill every slot, a burst of file events waits briefly instead of failing.
    func acquire(_ key: String, waitingUpTo limit: Duration) async throws {
        let deadline = ContinuousClock.now + limit
        while true {
            let admission: Admission = lock.withLock {
                if active.contains(key) { return .duplicate }
                guard active.count < 4 else { return .full }
                active.insert(key)
                return .admitted
            }
            switch admission {
            case .admitted: return
            case .duplicate:
                throw MonitoringError.blocked(reason: "A provider or writer check is still running. Wait for it to finish before retrying.")
            case .full:
                guard ContinuousClock.now < deadline else {
                    throw MonitoringError.blocked(reason: "Too many provider or writer checks are running. Try again in a moment.")
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
    }
    func release(_ key: String) { _ = lock.withLock { active.remove(key) } }
}

private final class ProcessCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CommandResult, Error>?
    private var deadline: DispatchWorkItem?
    init(_ continuation: CheckedContinuation<CommandResult, Error>) { self.continuation = continuation }
    func setDeadline(_ deadline: DispatchWorkItem) { lock.withLock { self.deadline = deadline } }
    func finish(_ result: Result<CommandResult, Error>) {
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            deadline?.cancel()
            deadline = nil
            return pending
        }
        pending?.resume(with: result)
    }
}

private final class LimitedCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var captured = Data()
    private var overflow = false
    init(limit: Int) { self.limit = limit }
    func append(_ bytes: Data) {
        lock.withLock {
            let remaining = max(0, limit - captured.count)
            if bytes.count > remaining { overflow = true }
            captured.append(bytes.prefix(remaining))
        }
    }
    var exceeded: Bool { lock.withLock { overflow } }
    var data: Data { lock.withLock { captured } }
}

public struct SystemOpenWriteProbe: OpenWriteProbing {
    public init() {}
    public func isOpenForWriting(path: String) async throws -> Bool {
        let result = try await BoundedProcess.run(executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-F", "a", "--", path], timeout: 5, outputLimit: 65_536)
        return try Self.interpret(result)
    }

    public static func interpret(_ result: CommandResult) throws -> Bool {
        guard result.standardError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MonitoringError.blocked(reason: "The open-file check reported an error.")
        }
        if result.exitCode == 1, result.standardOutput.isEmpty { return false }
        guard result.exitCode == 0 else {
            throw MonitoringError.blocked(reason: "The open-file check did not complete successfully.")
        }
        var sawAccess = false
        for line in result.standardOutput.split(separator: "\n") {
            guard let field = line.first else { continue }
            switch field {
            case "p", "f":
                guard !line.dropFirst().isEmpty else { throw MonitoringError.blocked(reason: "The open-file check is incomplete.") }
            case "a":
                let mode = String(line.dropFirst())
                guard ["r", "w", "u"].contains(mode) else { throw MonitoringError.blocked(reason: "The open-file check has an unknown access mode.") }
                sawAccess = true
                if mode == "w" || mode == "u" { return true }
            default:
                throw MonitoringError.blocked(reason: "The open-file check has an unsupported field.")
            }
        }
        guard sawAccess else { throw MonitoringError.blocked(reason: "The open-file check has no access information.") }
        return false
    }
}
