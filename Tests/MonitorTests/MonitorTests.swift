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
private func waitUntil(_ predicate: () async -> Bool) async throws {
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
