import Foundation
import Testing
import TrackerCore
@testable import TailscaleGPUTracker

private actor QueryGate {
    private(set) var calls = 0
    private var pending: [Int: CheckedContinuation<GPUReading, Never>] = [:]

    func fetch() async -> GPUReading {
        let id = calls
        calls += 1
        return await withCheckedContinuation { pending[id] = $0 }
    }

    func finish(_ id: Int, utilization: Double) {
        pending.removeValue(forKey: id)?.resume(returning: GPUReading(gpus: [GPU(index: 0, utilization: utilization)]))
    }
}

@MainActor
func waitUntil(_ predicate: () async -> Bool) async throws {
    for _ in 0..<100 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for monitor state")
}

@MainActor
private func makeStore(gate: QueryGate) -> (MonitorStore, String) {
    let suite = "io.qzgao.TailscaleGPUTracker.test.\(UUID().uuidString)"
    let store = MonitorStore(defaults: UserDefaults(suiteName: suite)!, discover: {
        try TailnetSnapshot.parse(Data(#"{"BackendState":"Running","Peer":{"key":{"ID":"one","HostName":"gpu","DNSName":"gpu.example.ts.net.","Online":true}}}"#.utf8))
    }, fetchGPU: { _, _ in await gate.fetch() })
    return (store, suite)
}

@Test @MainActor func discoveryDoesNotMonitorUncheckedMachines() async throws {
    let gate = QueryGate()
    let (store, suite) = makeStore(gate: gate)
    defer { store.stop(); UserDefaults().removePersistentDomain(forName: suite) }
    store.refreshMachines(pollAfter: true)
    try await waitUntil { store.hasDiscovered }
    #expect(store.rows.count == 1)
    #expect(store.selectedRows.isEmpty)
    #expect(await gate.calls == 0)
}

@Test @MainActor func refreshKeepsPreviousReadingAndAvoidsOverlappingQueries() async throws {
    let gate = QueryGate()
    let (store, suite) = makeStore(gate: gate)
    defer { store.stop(); UserDefaults().removePersistentDomain(forName: suite) }
    store.refreshMachines()
    try await waitUntil { store.hasDiscovered }
    let row = try #require(store.rows.first)
    store.setUsername("ubuntu", for: row)
    store.setEnabled(true, for: row)
    try await waitUntil { await gate.calls == 1 }
    await gate.finish(0, utilization: 90)
    try await waitUntil { row.state.reading?.total == 90 }
    store.refresh(row)
    store.refresh(row)
    try await waitUntil { await gate.calls == 2 }
    guard case .loading(let previous) = row.state else { Issue.record("Expected loading state"); return }
    #expect(previous?.total == 90)
    #expect(await gate.calls == 2)
    await gate.finish(1, utilization: 42)
    try await waitUntil { row.state.reading?.total == 42 }
}

@Test @MainActor func uncheckedMachineCannotReceiveLateResult() async throws {
    let gate = QueryGate()
    let (store, suite) = makeStore(gate: gate)
    defer { store.stop(); UserDefaults().removePersistentDomain(forName: suite) }
    store.refreshMachines()
    try await waitUntil { store.hasDiscovered }
    let row = try #require(store.rows.first)
    store.setUsername("ubuntu", for: row)
    store.setEnabled(true, for: row)
    try await waitUntil { await gate.calls == 1 }
    store.setEnabled(false, for: row)
    await gate.finish(0, utilization: 99)
    try await Task.sleep(for: .milliseconds(30))
    #expect(row.state == .idle)
    #expect(store.selectedRows.isEmpty)
}

@Test @MainActor func changingUsernameRejectsOldInflightResult() async throws {
    let gate = QueryGate()
    let (store, suite) = makeStore(gate: gate)
    defer { store.stop(); UserDefaults().removePersistentDomain(forName: suite) }
    store.refreshMachines()
    try await waitUntil { store.hasDiscovered }
    let row = try #require(store.rows.first)
    store.setUsername("ubuntu", for: row)
    store.setEnabled(true, for: row)
    try await waitUntil { await gate.calls == 1 }
    store.setUsername("research", for: row)
    try await waitUntil { await gate.calls == 2 }
    await gate.finish(1, utilization: 25)
    try await waitUntil { row.state.reading?.total == 25 }
    await gate.finish(0, utilization: 99)
    try await Task.sleep(for: .milliseconds(30))
    #expect(row.state.reading?.total == 25)
}

private actor RecoveryClient {
    var failure: String?
    var holdDiscovery = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var discoveries = 0
    private(set) var queriedIDs: [String] = []

    func configure(failure: String? = nil, holdDiscovery: Bool = false) {
        self.failure = failure
        self.holdDiscovery = holdDiscovery
    }

    func discover() async throws -> TailnetSnapshot {
        discoveries += 1
        if holdDiscovery { await withCheckedContinuation { continuation = $0 } }
        if let failure { throw TrackerError(failure) }
        return try TailnetSnapshot.parse(Data(#"""
        {"BackendState":"Running","Peer":{
          "a":{"ID":"one","HostName":"gpu-1","DNSName":"gpu-1.example.ts.net.","Online":true},
          "b":{"ID":"two","HostName":"gpu-2","DNSName":"gpu-2.example.ts.net.","Online":true}
        }}
        """#.utf8))
    }

    func releaseDiscovery() {
        holdDiscovery = false
        continuation?.resume()
        continuation = nil
    }

    func fetch(_ machine: Machine) -> GPUReading {
        queriedIDs.append(machine.id)
        return GPUReading(gpus: [GPU(index: 0, utilization: 90)])
    }
}

@MainActor
private func storeWithDiscoveryFailure(_ client: RecoveryClient) async throws -> (MonitorStore, String) {
    let suite = "io.qzgao.TailscaleGPUTracker.test.\(UUID().uuidString)"
    let store = MonitorStore(defaults: UserDefaults(suiteName: suite)!,
        discover: { try await client.discover() }, fetchGPU: { machine, _ in await client.fetch(machine) })
    store.refreshMachines()
    try await waitUntil { store.hasDiscovered }
    for row in store.rows {
        store.setUsername("ubuntu", for: row)
        store.setEnabled(true, for: row)
    }
    try await waitUntil { store.rows.allSatisfy { $0.state.reading != nil } }
    await client.configure(failure: "Tailscale disconnected")
    store.refreshMachines(pollAfter: true)
    try await waitUntil { store.discoveryError != nil }
    return (store, suite)
}

@Test @MainActor func cellRetryRediscoversOnceAndQueriesOnlyRequestedMachine() async throws {
    let client = RecoveryClient()
    let (store, suite) = try await storeWithDiscoveryFailure(client)
    defer { store.stop(); UserDefaults().removePersistentDomain(forName: suite) }
    await client.configure(holdDiscovery: true)
    let row = try #require(store.rows.first)
    store.refresh(row)
    store.refresh(row)
    try await waitUntil { await client.discoveries == 3 }
    #expect(row.state == .loading(previous: nil))
    await client.releaseDiscovery()
    try await waitUntil { row.state.reading != nil }
    #expect(store.discoveryError == nil)
    #expect(await client.discoveries == 3)
    #expect(await client.queriedIDs.count == 3)
    #expect(await client.queriedIDs.last == row.id)
    #expect(store.rows[1].state == .failed("Tailscale disconnected"))
}

@Test @MainActor func toolbarRecoveryRefreshesEnabledRows() async throws {
    let client = RecoveryClient()
    let (store, suite) = try await storeWithDiscoveryFailure(client)
    defer { store.stop(); UserDefaults().removePersistentDomain(forName: suite) }
    await client.configure()
    store.refreshMachines()
    try await waitUntil { store.rows.allSatisfy { $0.state.reading != nil } }
    #expect(store.discoveryError == nil)
    #expect(await client.queriedIDs.count == 4)
}

@Test @MainActor func failedCellRetryShowsNewDiscoveryErrorWithoutLooping() async throws {
    let client = RecoveryClient()
    let (store, suite) = try await storeWithDiscoveryFailure(client)
    defer { store.stop(); UserDefaults().removePersistentDomain(forName: suite) }
    await client.configure(failure: "Tailscale needs login")
    store.refresh(store.rows[0])
    try await waitUntil { store.discoveryError == "Tailscale needs login" }
    #expect(store.rows[0].state == .failed("Tailscale needs login"))
    #expect(await client.discoveries == 3)
    #expect(await client.queriedIDs.count == 2)
}

@Test @MainActor func uncheckingRowDuringRecoveryPreventsGPUQuery() async throws {
    let client = RecoveryClient()
    let (store, suite) = try await storeWithDiscoveryFailure(client)
    defer { store.stop(); UserDefaults().removePersistentDomain(forName: suite) }
    await client.configure(holdDiscovery: true)
    let row = store.rows[0]
    store.refresh(row)
    try await waitUntil { await client.discoveries == 3 }
    store.setEnabled(false, for: row)
    await client.releaseDiscovery()
    try await waitUntil { !store.discovering }
    #expect(row.state == .idle)
    #expect(await client.queriedIDs.count == 2)
}
