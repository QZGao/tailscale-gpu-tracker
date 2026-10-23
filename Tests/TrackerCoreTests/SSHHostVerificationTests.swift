import Foundation
import Testing
@testable import TrackerCore

@Test func ordinarySSHVerifiesDNSKnownHostWithTailnetAddressPresent() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gpu-ssh-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                          attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: folder) }
    let runner = ProcessRunner()
    let key = folder.appendingPathComponent("host_key")
    let generated = try await runner.run(executable: "/usr/bin/ssh-keygen",
        arguments: ["-q", "-t", "ed25519", "-N", "", "-f", key.path], timeout: 5)
    try #require(generated.status == 0)
    let knownHosts = folder.appendingPathComponent("known_hosts")
    let publicKey = try String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8)
    try "gpu.example.ts.net \(publicKey)".write(to: knownHosts, atomically: true, encoding: .utf8)

    // sshd runs over a local pipe. It opens no listening port and permits no login.
    let config = folder.appendingPathComponent("sshd_config")
    try """
    HostKey "\(key.path)"
    UsePAM no
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PubkeyAuthentication no
    HostbasedAuthentication no
    PermitEmptyPasswords no
    LogLevel ERROR
    """.write(to: config, atomically: true, encoding: .utf8)
    let log = folder.appendingPathComponent("sshd.log")
    let common = ["-F", "/dev/null", "-o", "LogLevel=DEBUG1",
                  "-o", "ProxyCommand=/usr/sbin/sshd -i -f \(shellQuote(config.path)) -E \(shellQuote(log.path))",
                  "-o", "UserKnownHostsFile=\"\(knownHosts.path)\"",
                  "-o", "GlobalKnownHostsFile=/dev/null", "-o", "IdentityAgent=none", "-o", "IdentityFile=none"]
    let machine = Machine(id: "one", name: "gpu", dnsName: "gpu.example.ts.net", addresses: ["100.64.0.1"], online: true)
    let args = try GPUClient.arguments(machine: machine, username: "gpu_test_no_login", knownHosts: nil)
    let result = try await runner.run(executable: "/usr/bin/ssh", arguments: common + args, timeout: 5)
    #expect(result.error.contains("Host 'gpu.example.ts.net' is known and matches the ED25519 host key."))
    #expect(!result.error.contains("Host key verification failed"))
    // Host verification succeeds; the fixture deliberately rejects authentication.
    #expect(result.status == 255)
    #expect(result.error.contains("Permission denied"))
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
