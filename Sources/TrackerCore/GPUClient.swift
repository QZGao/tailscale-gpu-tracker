import Foundation

public struct GPUClient: Sendable {
    public init() {}
    public static let query = "nvidia-smi --query-gpu=index,utilization.gpu --format=csv,noheader,nounits"

    public static func validateUsername(_ username: String) throws {
        guard !username.isEmpty else { throw TrackerError("Enter an SSH username.") }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.@\\$")
        guard !username.hasPrefix("-"), username.unicodeScalars.allSatisfy(allowed.contains), username.count <= 128 else {
            throw TrackerError("Enter a valid SSH username.")
        }
    }

    public static func arguments(machine: Machine, username: String, knownHosts: String?) throws -> [String] {
        try validateUsername(username)
        let host = machine.destination
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:")
        guard !host.isEmpty, !host.hasPrefix("-"), host.unicodeScalars.allSatisfy(allowed.contains) else {
            throw TrackerError("This machine has no valid Tailscale address.")
        }
        var args = ["-n", "-T", "-a", "-x", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                    "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=1",
                    "-o", "StrictHostKeyChecking=yes", "-o", "ClearAllForwardings=yes", "-o", "PermitLocalCommand=no",
                    "-o", "RemoteCommand=none", "-o", "ControlMaster=no", "-o", "ControlPath=none",
                    "-o", "LogLevel=ERROR"]
        if let knownHosts {
            // These keys come from the authenticated local Tailscale daemon.
            args += ["-o", "UserKnownHostsFile=\"\(knownHosts)\"", "-o", "GlobalKnownHostsFile=/dev/null",
                     "-o", "HostKeyAlias=\(host)", "-o", "CheckHostIP=no"]
        }
        // Use the Tailscale IP for transport, even if MagicDNS is disabled locally.
        // SSH still matches the machine's MagicDNS name against the user's SSH config.
        if let address = machine.addresses.first, address.unicodeScalars.allSatisfy(allowed.contains) {
            args += ["-o", "Hostname=\(address)"]
        }
        args += ["-l", username, host, query]
        return args
    }

    public func fetch(machine: Machine, username: String) async throws -> GPUReading {
        try Self.validateUsername(username)
        guard machine.online else { throw TrackerError("Machine is offline.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tailscale-gpu-keys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var knownHosts: String?
        if !machine.sshHostKeys.isEmpty {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
            let file = folder.appendingPathComponent("known_hosts")
            let keys = machine.sshHostKeys.filter { !$0.contains("\n") && !$0.contains("\r") }
            guard keys.count == machine.sshHostKeys.count else { throw TrackerError("Invalid Tailscale SSH host key.") }
            let contents = keys.map { "\(machine.destination) \($0)\n" }.joined()
            try Data(contents.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            knownHosts = file.path
        }
        let result = try await ProcessRunner().run(executable: "/usr/bin/ssh",
            arguments: Self.arguments(machine: machine, username: username, knownHosts: knownHosts), timeout: 15)
        guard result.status == 0 else {
            let detail = (result.error.isEmpty ? result.output : result.error).trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.contains("nvidia-smi") && (detail.contains("not found") || detail.contains("not recognized")) {
                throw TrackerError("nvidia-smi was not found on this machine.")
            }
            throw TrackerError(detail.isEmpty ? "SSH exited with status \(result.status)." : String(detail.prefix(1200)))
        }
        return try GPUReading.parse(result.output)
    }
}
