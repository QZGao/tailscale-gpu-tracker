import Foundation

public struct TailnetSnapshot: Sendable {
    public let machines: [Machine]
    public let name: String

    public static func parse(_ data: Data) throws -> TailnetSnapshot {
        let status: Status
        do { status = try JSONDecoder().decode(Status.self, from: data) }
        catch { throw TrackerError("Tailscale returned an unreadable machine list.") }
        guard status.BackendState == "Running" else {
            throw TrackerError("Tailscale is \(status.BackendState ?? "unavailable"). Connect using the installed Tailscale app.")
        }
        var peers = status.Peer ?? [:]
        if let local = status.local { peers[local.ID ?? "self"] = local }
        var seen = Set<String>()
        let machines = peers.sorted { $0.key < $1.key }.compactMap { key, peer -> Machine? in
            let id = peer.ID ?? key
            guard seen.insert(id).inserted else { return nil }
            return Machine(id: id,
                    name: peer.HostName?.isEmpty == false ? peer.HostName! : (peer.DNSName ?? "Unknown machine"),
                    dnsName: (peer.DNSName ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ".")),
                    addresses: peer.TailscaleIPs ?? [], online: peer.Online ?? false,
                    sshHostKeys: peer.sshHostKeys ?? [])
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return TailnetSnapshot(machines: machines, name: status.CurrentTailnet?.Name ?? "Tailscale")
    }

    private struct Status: Decodable {
        var BackendState: String?
        var Peer: [String: PeerStatus]?
        var CurrentTailnet: Tailnet?
        var local: PeerStatus?
        enum CodingKeys: String, CodingKey {
            case BackendState, Peer, CurrentTailnet
            case local = "Self"
        }
    }
    private struct Tailnet: Decodable { var Name: String? }
    private struct PeerStatus: Decodable {
        var ID: String?
        var HostName: String?
        var DNSName: String?
        var TailscaleIPs: [String]?
        var Online: Bool?
        var sshHostKeys: [String]?
    }
}

public struct TailscaleClient: Sendable {
    // The macOS app executable otherwise guesses GUI/CLI mode from shell variables.
    // Finder launches do not have those variables.
    static let commandEnvironment = ["TAILSCALE_BE_CLI": "1"]

    public init() {}

    public static func executable() throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "\(home)/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"
        ] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/tailscale" }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw TrackerError("Tailscale was not found. Install and connect Tailscale, then refresh.")
        }
        return path
    }

    public func discover() async throws -> TailnetSnapshot {
        let result = try await ProcessRunner().run(executable: Self.executable(), arguments: ["status", "--json"],
                                                 timeout: 12, environmentOverrides: Self.commandEnvironment)
        guard result.status == 0, result.output.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") else {
            let message = (result.error.isEmpty ? result.output : result.error).trimmingCharacters(in: .whitespacesAndNewlines)
            throw TrackerError(message.isEmpty ? "Unable to read the installed Tailscale client." : String(message.prefix(800)))
        }
        return try TailnetSnapshot.parse(Data(result.output.utf8))
    }
}
