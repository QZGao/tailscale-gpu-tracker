import Foundation

public struct TrackerError: LocalizedError, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct Machine: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let dnsName: String
    public let addresses: [String]
    public let online: Bool
    public let sshHostKeys: [String]

    public init(id: String, name: String, dnsName: String, addresses: [String], online: Bool, sshHostKeys: [String] = []) {
        self.id = id
        self.name = name
        self.dnsName = dnsName
        self.addresses = addresses
        self.online = online
        self.sshHostKeys = sshHostKeys
    }

    public var destination: String { dnsName.isEmpty ? (addresses.first ?? "") : dnsName }
}

public struct MachinePreferences: Codable, Equatable, Sendable {
    public var alias: String
    public var username: String
    public var enabled: Bool

    public init(alias: String = "", username: String = "", enabled: Bool = false) {
        self.alias = alias
        self.username = username
        self.enabled = enabled
    }

    public func displayName(for machine: Machine) -> String { alias.isEmpty ? machine.name : alias }
}

public struct GPU: Identifiable, Equatable, Sendable {
    public let index: Int
    public let utilization: Double?
    public var id: Int { index }
    public init(index: Int, utilization: Double?) {
        self.index = index
        self.utilization = utilization
    }
}

public struct GPUReading: Equatable, Sendable {
    public let gpus: [GPU]
    public let date: Date

    public init(gpus: [GPU], date: Date = Date()) {
        self.gpus = gpus
        self.date = date
    }

    // A partial reading must not turn unavailable GPUs into idle GPUs.
    public var total: Int? {
        guard !gpus.isEmpty, gpus.allSatisfy({ $0.utilization != nil }) else { return nil }
        return Int((gpus.compactMap(\.utilization).reduce(0, +) / Double(gpus.count)).rounded())
    }

    public static func parse(_ output: String) throws -> GPUReading {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { throw TrackerError("No NVIDIA GPUs reported.") }
        var gpus: [GPU] = []
        var indices = Set<Int>()
        for line in lines {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 2, let index = Int(fields[0]), index >= 0, indices.insert(index).inserted else {
                throw TrackerError("Unexpected nvidia-smi response: \(line.prefix(180))")
            }
            let value: Double?
            if ["N/A", "[N/A]", "[Not Supported]", "Not Supported"].contains(fields[1]) {
                value = nil
            } else {
                guard let number = Double(fields[1]), number.isFinite, (0...100).contains(number) else {
                    throw TrackerError("Invalid GPU utilization: \(fields[1].prefix(80))")
                }
                value = number
            }
            gpus.append(GPU(index: index, utilization: value))
        }
        return GPUReading(gpus: gpus.sorted { $0.index < $1.index })
    }
}

public enum MonitorState: Equatable, Sendable {
    case idle
    case loading(previous: GPUReading?)
    case ready(GPUReading)
    case failed(String)

    public var reading: GPUReading? {
        switch self {
        case .ready(let reading): return reading
        case .loading(let previous): return previous
        case .idle, .failed: return nil
        }
    }
}
