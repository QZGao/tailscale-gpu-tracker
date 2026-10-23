import AppKit
import Combine
import TrackerCore

@MainActor
final class MachineRow: ObservableObject, Identifiable {
    let id: String
    @Published var machine: Machine
    @Published var preferences: MachinePreferences
    @Published var state: MonitorState = .idle

    init(machine: Machine, preferences: MachinePreferences) {
        id = machine.id
        self.machine = machine
        self.preferences = preferences
    }

    var displayName: String { preferences.displayName(for: machine) }
}

@MainActor
final class MonitorStore: ObservableObject {
    @Published private(set) var rows: [MachineRow] = []
    @Published private(set) var discovering = false
    @Published private(set) var discoveryError: String?
    @Published private(set) var tailnet = "Tailscale"
    @Published private(set) var hasDiscovered = false
    @Published private(set) var revision = 0
    var onChange: (() -> Void)?

    private var preferences: [String: MachinePreferences]
    private let defaults: UserDefaults
    private let discover: @Sendable () async throws -> TailnetSnapshot
    private let fetchGPU: @Sendable (Machine, String) async throws -> GPUReading
    private var discoveryTask: Task<Void, Never>?
    private var refreshAllAfterDiscovery = false
    private var retryAfterDiscovery = Set<String>()
    private var queries: [String: Task<Void, Never>] = [:]
    private var queryIDs: [String: UUID] = [:]
    private var timer: Timer?

    init(defaults: UserDefaults = .standard,
         discover: @escaping @Sendable () async throws -> TailnetSnapshot = { try await TailscaleClient().discover() },
         fetchGPU: @escaping @Sendable (Machine, String) async throws -> GPUReading = { try await GPUClient().fetch(machine: $0, username: $1) }) {
        self.defaults = defaults
        self.discover = discover
        self.fetchGPU = fetchGPU
        preferences = defaults.data(forKey: "machines").flatMap {
            try? JSONDecoder().decode([String: MachinePreferences].self, from: $0)
        } ?? [:]
    }

    var selectedRows: [MachineRow] { rows.filter { $0.preferences.enabled } }

    func start() {
        refreshMachines(pollAfter: true)
        // Manual cell refreshes never reset this timer.
        timer = Timer(timeInterval: 60, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleep),
            name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    func stop() {
        timer?.invalidate()
        discoveryTask?.cancel()
        refreshAllAfterDiscovery = false
        retryAfterDiscovery.removeAll()
        for task in queries.values { task.cancel() }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func tick() { refreshMachines(pollAfter: true) }
    @objc private func wake() { refreshMachines(pollAfter: true) }
    @objc private func sleep() {
        discoveryTask?.cancel()
        discoveryTask = nil
        discovering = false
        refreshAllAfterDiscovery = false
        retryAfterDiscovery.removeAll()
        for row in selectedRows {
            cancelQuery(row.id)
            row.state = row.state.reading.map(MonitorState.ready) ?? .idle
        }
        changed()
    }

    func refreshMachines(pollAfter: Bool = false) {
        refreshAllAfterDiscovery = refreshAllAfterDiscovery || pollAfter || discoveryError != nil
        beginDiscovery()
    }

    private func beginDiscovery() {
        guard discoveryTask == nil else { return }
        discovering = true
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await discover()
                try Task.checkCancellation()
                let existing = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
                var changedMachines = Set<String>()
                let presentIDs = Set(snapshot.machines.map(\.id))
                for id in Array(queries.keys) where !presentIDs.contains(id) { cancelQuery(id) }
                rows = snapshot.machines.map { machine in
                    if let row = existing[machine.id] {
                        if row.machine != machine {
                            cancelQuery(row.id)
                            row.machine = machine
                            if case .loading = row.state {
                                row.state = row.state.reading.map(MonitorState.ready) ?? .idle
                            }
                            changedMachines.insert(row.id)
                        }
                        return row
                    }
                    return MachineRow(machine: machine, preferences: preferences[machine.id] ?? MachinePreferences())
                }
                tailnet = snapshot.name
                discoveryError = nil
                hasDiscovered = true
                if refreshAllAfterDiscovery {
                    refreshSelected()
                } else if !retryAfterDiscovery.isEmpty {
                    for row in selectedRows where retryAfterDiscovery.contains(row.id) { query(row) }
                } else {
                    for row in selectedRows where row.state == .idle || changedMachines.contains(row.id) { query(row) }
                }
            } catch {
                guard !Task.isCancelled else { return }
                discoveryError = error.localizedDescription
                for row in selectedRows {
                    cancelQuery(row.id)
                    row.state = .failed(error.localizedDescription)
                }
            }
            refreshAllAfterDiscovery = false
            retryAfterDiscovery.removeAll()
            discovering = false
            discoveryTask = nil
            changed()
        }
    }

    func setEnabled(_ enabled: Bool, for row: MachineRow) {
        row.preferences.enabled = enabled
        save(row)
        cancelQuery(row.id)
        row.state = .idle
        if enabled { refresh(row) }
        changed()
    }

    func setAlias(_ alias: String, for row: MachineRow) {
        row.preferences.alias = String(alias.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        save(row)
        changed()
    }

    func setUsername(_ username: String, for row: MachineRow) {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard username != row.preferences.username else { return }
        row.preferences.username = username
        save(row)
        cancelQuery(row.id)
        if row.preferences.enabled { refresh(row) }
        changed()
    }

    private func refreshSelected() { for row in selectedRows { query(row) } }

    func refresh(_ row: MachineRow) {
        guard row.preferences.enabled, queries[row.id] == nil else { return }
        if discoveryError != nil {
            retryAfterDiscovery.insert(row.id)
            row.state = .loading(previous: row.state.reading)
            beginDiscovery()
            changed()
        } else {
            query(row)
        }
    }

    private func query(_ row: MachineRow) {
        guard row.preferences.enabled, queries[row.id] == nil else { return }
        if let discoveryError {
            row.state = .failed(discoveryError)
            changed()
            return
        }
        do { try GPUClient.validateUsername(row.preferences.username) }
        catch {
            row.state = .failed(error.localizedDescription)
            changed()
            return
        }
        guard row.machine.online else {
            row.state = .failed("Machine is offline.")
            changed()
            return
        }
        let id = UUID()
        queryIDs[row.id] = id
        row.state = .loading(previous: row.state.reading)
        let machine = row.machine
        let username = row.preferences.username
        queries[row.id] = Task { [weak self, weak row] in
            guard let self, let row else { return }
            let state: MonitorState
            do {
                let reading = try await fetchGPU(machine, username)
                state = .ready(reading)
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(error.localizedDescription)
            }
            guard !Task.isCancelled, queryIDs[row.id] == id, row.preferences.enabled else { return }
            row.state = state
            queries[row.id] = nil
            queryIDs[row.id] = nil
            changed()
        }
        changed()
    }

    private func cancelQuery(_ id: String) {
        queries.removeValue(forKey: id)?.cancel()
        queryIDs[id] = nil
    }

    private func save(_ row: MachineRow) {
        preferences[row.id] = row.preferences
        if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: "machines") }
    }

    private func changed() {
        revision += 1
        onChange?()
    }
}
