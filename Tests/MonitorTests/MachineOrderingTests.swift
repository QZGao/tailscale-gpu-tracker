import Foundation
import Testing
import TrackerCore
@testable import TailscaleGPUTracker

private actor MachineList {
    private var names = ["alpha": "Alpha", "beta": "Beta", "gamma": "Gamma"]
    private(set) var queries = 0

    func setNames(_ names: [String: String]) { self.names = names }

    func discover() throws -> TailnetSnapshot {
        let peers = names.mapValues { ["HostName": $0, "Online": true] as [String: Any] }
        return try TailnetSnapshot.parse(JSONSerialization.data(withJSONObject: [
            "BackendState": "Running", "Peer": peers
        ]))
    }

    func fetch() -> GPUReading {
        queries += 1
        return GPUReading(gpus: [GPU(index: 0, utilization: 42)])
    }
}

@MainActor
private func orderingStore(defaults: UserDefaults, machines: MachineList) -> MonitorStore {
    MonitorStore(defaults: defaults, discover: { try await machines.discover() },
                 fetchGPU: { _, _ in await machines.fetch() })
}

@Test @MainActor func movingMachinesUpdatesMenuOrderAndPreservesRows() async throws {
    let suite = "io.qzgao.TailscaleGPUTracker.test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let machines = MachineList()
    let store = orderingStore(defaults: defaults, machines: machines)
    defer { store.stop(); defaults.removePersistentDomain(forName: suite) }
    store.refreshMachines()
    try await waitUntil { store.hasDiscovered }
    let original = store.rows
    #expect(original.map(\.id) == ["alpha", "beta", "gamma"])
    for row in [original[0], original[2]] {
        store.setUsername("ubuntu", for: row)
        store.setEnabled(true, for: row)
    }
    store.setAlias("Compute", for: original[2])
    try await waitUntil { store.selectedRows.allSatisfy { $0.state.reading != nil } }
    let readings = original.map(\.state)
    var menuOrder: [String] = []
    store.onChange = { menuOrder = store.selectedRows.map(\.id) }

    store.moveMachine("gamma", toOffset: 0)
    #expect(store.rows.map(\.id) == ["gamma", "alpha", "beta"])
    #expect(menuOrder == ["gamma", "alpha"])
    #expect(store.rows[0] === original[2])
    #expect(store.rows[1] === original[0])
    #expect(store.rows[2] === original[1])
    #expect(original.map(\.state) == readings)
    #expect(store.rows[0].displayName == "Compute")
    #expect(store.rows[0].preferences.username == "ubuntu")
    #expect(await machines.queries == 2)

    store.moveMachine("gamma", toOffset: store.rows.count)
    #expect(store.rows.map(\.id) == ["alpha", "beta", "gamma"])
    #expect(menuOrder == ["alpha", "gamma"])
    store.moveMachine("alpha", toOffset: 2)
    #expect(store.rows.map(\.id) == ["beta", "alpha", "gamma"])
    #expect(defaults.stringArray(forKey: "machineOrder") == ["beta", "alpha", "gamma"])
}

@Test @MainActor func manualOrderSurvivesDiscoveryMissingMachinesAndRestart() async throws {
    let suite = "io.qzgao.TailscaleGPUTracker.test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let machines = MachineList()
    let store = orderingStore(defaults: defaults, machines: machines)
    defer { store.stop(); defaults.removePersistentDomain(forName: suite) }
    store.refreshMachines()
    try await waitUntil { store.hasDiscovered }
    store.moveMachine("gamma", toOffset: 0)

    // A rename changes discovery's alphabetical order; a new machine sorts first there.
    await machines.setNames(["alpha": "Zulu", "gamma": "Gamma", "new": "Aardvark"])
    store.refreshMachines()
    try await waitUntil { !store.discovering }
    #expect(store.rows.map(\.id) == ["gamma", "alpha", "new"])
    #expect(store.rows[1].machine.name == "Zulu")
    store.moveMachine("new", toOffset: 0)
    #expect(store.rows.map(\.id) == ["new", "gamma", "alpha"])

    await machines.setNames(["alpha": "Zulu", "beta": "Beta", "gamma": "Gamma", "new": "Aardvark"])
    store.refreshMachines()
    try await waitUntil { !store.discovering }
    #expect(store.rows.map(\.id) == ["new", "gamma", "beta", "alpha"])

    let restored = orderingStore(defaults: UserDefaults(suiteName: suite)!, machines: machines)
    defer { restored.stop() }
    restored.refreshMachines()
    try await waitUntil { restored.hasDiscovered }
    #expect(restored.rows.map(\.id) == store.rows.map(\.id))
}

@Test @MainActor func invalidAndUnchangedDropsDoNotSaveOrNotify() async throws {
    let suite = "io.qzgao.TailscaleGPUTracker.test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let store = orderingStore(defaults: defaults, machines: MachineList())
    defer { store.stop(); defaults.removePersistentDomain(forName: suite) }
    store.refreshMachines()
    try await waitUntil { store.hasDiscovered }
    let revision = store.revision
    var changes = 0
    store.onChange = { changes += 1 }
    store.moveMachine("unknown", toOffset: 0)
    store.moveMachine("alpha", toOffset: -1)
    store.moveMachine("alpha", toOffset: 4)
    store.moveMachine("beta", toOffset: 1)
    store.moveMachine("beta", toOffset: 2)
    #expect(store.rows.map(\.id) == ["alpha", "beta", "gamma"])
    #expect(store.revision == revision)
    #expect(changes == 0)
    #expect(defaults.object(forKey: "machineOrder") == nil)
}
