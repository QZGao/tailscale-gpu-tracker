import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let output: String
    public let error: String
}

/// Each command owns its files and process. Cancellation also stops the subprocess.
public struct ProcessRunner: Sendable {
    public init() {}

    public func run(executable: String, arguments: [String], timeout: TimeInterval,
                    environmentOverrides: [String: String] = [:]) async throws -> CommandResult {
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try Self.execute(executable: executable, arguments: arguments, timeout: timeout,
                                 environmentOverrides: environmentOverrides, cancellation: cancellation)
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func execute(executable: String, arguments: [String], timeout: TimeInterval,
                                environmentOverrides: [String: String],
                                cancellation: CancellationFlag) throws -> CommandResult {
        if cancellation.isCancelled { throw CancellationError() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tailscale-gpu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let stdout = folder.appendingPathComponent("stdout")
        let stderr = folder.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdout.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: stderr.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let outHandle = try FileHandle(forWritingTo: stdout)
        let errHandle = try FileHandle(forWritingTo: stderr)
        defer { try? outHandle.close(); try? errHandle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outHandle
        process.standardError = errHandle
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["SSH_ASKPASS_REQUIRE"] = "never"
        environment.merge(environmentOverrides) { _, override in override }
        process.environment = environment
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if cancellation.isCancelled || Date() >= deadline {
                timedOut = !cancellation.isCancelled
                process.terminate()
                let grace = Date().addingTimeInterval(0.3)
                while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.04)
        }
        process.waitUntilExit()
        if cancellation.isCancelled { throw CancellationError() }
        let output = try readLimited(stdout)
        let error = try readLimited(stderr)
        if timedOut {
            let detail = error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw TrackerError(detail.isEmpty ? "Connection timed out." : "Connection timed out. \(detail.prefix(600))")
        }
        return CommandResult(status: process.terminationStatus, output: output, error: error)
    }

    private static func readLimited(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return String(decoding: try file.read(upToCount: 2_000_000) ?? Data(), as: UTF8.self)
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
