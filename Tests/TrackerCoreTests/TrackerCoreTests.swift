import Foundation
import Testing
@testable import TrackerCore

@Test func discoversEveryMachineIncludingOfflineAndLocal() throws {
    let data = Data(#"""
    {"BackendState":"Running","CurrentTailnet":{"Name":"example"},
     "Self":{"ID":"local","HostName":"My Mac","DNSName":"mac.example.ts.net.","Online":true},
     "Peer":{
       "key2":{"ID":"two","HostName":"gpu-2","DNSName":"gpu-2.example.ts.net.","Online":false},
       "key1":{"ID":"one","HostName":"gpu-1","DNSName":"gpu-1.example.ts.net.","Online":true,
         "TailscaleIPs":["100.64.0.1"],"sshHostKeys":["ssh-ed25519 example"]}
     },"UnknownFutureField":true}
    """#.utf8)
    let snapshot = try TailnetSnapshot.parse(data)
    #expect(snapshot.machines.count == 3)
    #expect(snapshot.machines.first?.id == "one")
    #expect(snapshot.machines.first?.dnsName == "gpu-1.example.ts.net")
    #expect(snapshot.machines.first?.sshHostKeys == ["ssh-ed25519 example"])
    #expect(snapshot.machines.first { $0.id == "two" }?.online == false)
    #expect(snapshot.name == "example")
}

@Test func stoppedTailscaleGivesActionableError() {
    #expect(throws: TrackerError.self) {
        try TailnetSnapshot.parse(Data(#"{"BackendState":"NeedsLogin"}"#.utf8))
    }
}

@Test func emptyTailnetIsValid() throws {
    #expect(try TailnetSnapshot.parse(Data(#"{"BackendState":"Running","Peer":null}"#.utf8)).machines.isEmpty)
}

@Test func computesAverageAndSortsDevices() throws {
    let reading = try GPUReading.parse("3, 100\r\n1, 20\n0, 0\n2, 80\n")
    #expect(reading.total == 50)
    #expect(reading.gpus.map(\.index) == [0, 1, 2, 3])
}

@Test func unavailableIsNotIdle() throws {
    let reading = try GPUReading.parse("0, 90\n1, [N/A]\n")
    #expect(reading.total == nil)
    #expect(reading.gpus[0].utilization == 90)
    #expect(reading.gpus[1].utilization == nil)
}

@Test(arguments: ["", "No devices were found", "0, 101", "0, -1", "0, nan", "0, 25\n0, 75", "0, 20, 30"])
func rejectsInvalidGPUOutput(_ output: String) {
    #expect(throws: TrackerError.self) { try GPUReading.parse(output) }
}

@Test(arguments: ["", "-oProxyCommand=oops", "root;whoami", "root\nubuntu", "name with spaces"])
func rejectsInvalidUsernames(_ username: String) {
    #expect(throws: TrackerError.self) { try GPUClient.validateUsername(username) }
}

@Test func pinsAdvertisedKeysAndUsesTailnetAddress() throws {
    let machine = Machine(id: "one", name: "gpu", dnsName: "gpu.example.ts.net", addresses: ["100.64.0.1"], online: true)
    let args = try GPUClient.arguments(machine: machine, username: "root", knownHosts: "/tmp/has space/known_hosts")
    #expect(args.contains("StrictHostKeyChecking=yes"))
    #expect(args.contains("UserKnownHostsFile=\"/tmp/has space/known_hosts\""))
    #expect(args.contains("Hostname=100.64.0.1"))
    #expect(args.contains("HostKeyAlias=gpu.example.ts.net"))
    #expect(args.contains("BatchMode=yes"))
    #expect(args.suffix(4) == ["-l", "root", "gpu.example.ts.net", GPUClient.query])
}

@Test func ordinarySSHRetainsExistingKnownHosts() throws {
    let machine = Machine(id: "one", name: "gpu", dnsName: "gpu.example.ts.net", addresses: [], online: true)
    let args = try GPUClient.arguments(machine: machine, username: "ubuntu", knownHosts: nil)
    #expect(!args.contains { $0.hasPrefix("UserKnownHostsFile=") })
    #expect(args.contains("StrictHostKeyChecking=yes"))
}

@Test func newMachinesAreUncheckedAndPreferencesRoundTrip() throws {
    #expect(!MachinePreferences().enabled)
    let saved = MachinePreferences(alias: "Training", username: "ubuntu", enabled: true)
    let loaded = try JSONDecoder().decode(MachinePreferences.self, from: JSONEncoder().encode(saved))
    #expect(saved == loaded)
}

@Test func processCapturesBothStreamsAndExitStatus() async throws {
    let result = try await ProcessRunner().run(executable: "/bin/sh",
        arguments: ["-c", "printf '0, 42\\n'; printf 'diagnostic' >&2; exit 7"], timeout: 2)
    #expect(result.status == 7)
    #expect(result.output == "0, 42\n")
    #expect(result.error == "diagnostic")
}

@Test func tailscaleCommandExplicitlyRequestsCLIMode() async throws {
    let original = ProcessInfo.processInfo.environment["TAILSCALE_BE_CLI"]
    let result = try await ProcessRunner().run(executable: "/bin/sh",
        arguments: ["-c", "printf '%s' \"$TAILSCALE_BE_CLI\""], timeout: 2,
        environmentOverrides: TailscaleClient.commandEnvironment)
    #expect(result.status == 0)
    #expect(result.output == "1")
    #expect(ProcessInfo.processInfo.environment["TAILSCALE_BE_CLI"] == original)
}

@Test func timeoutStopsUnresponsiveProcess() async {
    let start = Date()
    await #expect(throws: TrackerError.self) {
        try await ProcessRunner().run(executable: "/bin/sleep", arguments: ["10"], timeout: 0.1)
    }
    #expect(Date().timeIntervalSince(start) < 2)
}

@Test func cancellationStopsRunningProcess() async throws {
    let task = Task { try await ProcessRunner().run(executable: "/bin/sleep", arguments: ["10"], timeout: 15) }
    try await Task.sleep(for: .milliseconds(100))
    let start = Date()
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("Cancelled process returned a result")
    } catch {
        #expect(error is CancellationError)
    }
    #expect(Date().timeIntervalSince(start) < 2)
}
