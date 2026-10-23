import AppKit
import SwiftUI
import TrackerCore

@MainActor
final class MainWindow: NSWindowController {
    init(store: MonitorStore) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1250, height: 550),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Tailscale GPU Tracker"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 800, height: 300)
        let content = NSHostingView(rootView: MachinesView(store: store))
        // The window owns its size; SwiftUI's ideal table size must not fix its bounds.
        content.sizingOptions = []
        window.contentView = content
        window.setFrameAutosaveName("MachinesWindow")
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("Use init(store:)") }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct MachinesView: View {
    @ObservedObject var store: MonitorStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Tailscale GPU Tracker").font(.system(size: 22, weight: .semibold))
                    HStack(spacing: 6) {
                        Circle().fill(store.discoveryError == nil && store.hasDiscovered ? Color.accentColor : Color.secondary.opacity(0.5))
                            .frame(width: 6, height: 6)
                        Text(store.hasDiscovered ? store.tailnet : "Your Tailscale machines")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if store.discovering { ProgressView().controlSize(.small).padding(.trailing, 5) }
                Button { store.refreshMachines() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .medium))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.borderless)
                .disabled(store.discovering)
                .help("Refresh machine list")
                .accessibilityLabel("Refresh machine list")
            }
            .padding(.horizontal, 24).padding(.top, 38).padding(.bottom, 22)

            if let error = store.discoveryError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .font(.callout).foregroundStyle(.red)
                .padding(.horizontal, 24).padding(.bottom, 16)
            }

            Table(store.rows) {
                TableColumn("") { row in
                    MonitorToggle(row: row, store: store)
                }.width(32)
                TableColumn("Machine") { row in
                    MachineName(row: row, store: store)
                }.width(min: 190, ideal: 240, max: 420)
                TableColumn("MagicDNS") { row in
                    MachineAddress(row: row)
                }.width(min: 220, ideal: 290, max: 450)
                TableColumn("SSH user") { row in
                    UsernameField(row: row, store: store)
                }.width(min: 95, ideal: 110, max: 180)
                TableColumn("GPU usage") { row in
                    UsageCell(row: row, store: store)
                }.width(min: 290, ideal: 360, max: 900)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .overlay {
                if store.rows.isEmpty && !store.discovering {
                    VStack(spacing: 10) {
                        Image(systemName: "network").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
                        Text(store.discoveryError == nil ? "No remote machines" : "Unable to read Tailscale")
                            .font(.headline).foregroundStyle(.secondary)
                        Text(store.discoveryError == nil ? "Machines in your tailnet will appear here." : "Check the installed Tailscale app, then refresh.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }

            Divider()
            HStack(spacing: 0) {
                Text("\(store.rows.count) machines · \(store.selectedRows.count) monitored")
                Spacer()
                Text("Updates every minute · Click GPU usage to refresh")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 24).padding(.vertical, 13)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct MonitorToggle: View {
    @ObservedObject var row: MachineRow
    let store: MonitorStore
    var body: some View {
        Toggle("Monitor \(row.displayName)", isOn: Binding(
            get: { row.preferences.enabled }, set: { store.setEnabled($0, for: row) }
        ))
        .toggleStyle(.checkbox).labelsHidden()
        .help("Monitor \(row.displayName)")
        .frame(height: 42)
    }
}

private struct MachineName: View {
    @ObservedObject var row: MachineRow
    let store: MonitorStore
    @State private var editing = false
    @State private var alias = ""
    @FocusState private var aliasFocused: Bool

    var body: some View {
        Button {
            alias = row.preferences.alias
            editing = true
        } label: {
            HStack(spacing: 6) {
                if !row.machine.online {
                    Circle().fill(.secondary.opacity(0.5)).frame(width: 5, height: 5)
                }
                if row.preferences.alias.isEmpty {
                    Text(row.machine.name).foregroundStyle(.primary)
                } else {
                    (Text(row.preferences.alias).foregroundColor(.primary) + Text(" (\(row.machine.name))").foregroundColor(.secondary))
                }
            }
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(row.machine.name)\(row.machine.online ? "" : " · Offline")\nClick to edit alias")
        .accessibilityLabel("\(row.displayName). Edit alias")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Machine alias").font(.headline)
                Text(row.machine.name).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                TextField("Alias (optional)", text: $alias).textFieldStyle(.roundedBorder)
                    .focused($aliasFocused).onSubmit(saveAlias)
                HStack {
                    Button("Cancel") { editing = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Save", action: saveAlias).keyboardShortcut(.defaultAction)
                }
            }
            .padding(18).frame(width: 280)
            .onAppear { aliasFocused = true }
        }
    }

    private func saveAlias() {
        store.setAlias(alias, for: row)
        editing = false
    }
}

private struct MachineAddress: View {
    @ObservedObject var row: MachineRow
    var body: some View {
        Text(row.machine.destination)
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            .help(row.machine.destination)
            .contextMenu {
                Button("Copy address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(row.machine.destination, forType: .string)
                }
            }
    }
}

private struct UsernameField: View {
    @ObservedObject var row: MachineRow
    let store: MonitorStore
    @State private var draft = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField("Username", text: $draft)
            .font(.system(size: 12)).textFieldStyle(.plain)
            .focused($focused)
            .onAppear { draft = row.preferences.username }
            .onSubmit { store.setUsername(draft, for: row); focused = false }
            .onChange(of: focused) { _, focused in
                if !focused { store.setUsername(draft, for: row) }
            }
            .help("Remote SSH account, such as root or ubuntu. Press Return to save.")
            .accessibilityLabel("SSH username for \(row.displayName)")
    }
}

private struct UsageCell: View {
    @ObservedObject var row: MachineRow
    let store: MonitorStore

    var body: some View {
        Group {
            if row.preferences.enabled {
                Button { store.refresh(row) } label: {
                    HStack(spacing: 10) {
                        switch row.state {
                        case .idle:
                            ProgressView().controlSize(.small)
                        case .loading(let previous):
                            ProgressView().controlSize(.small)
                            if let previous { readingView(previous) }
                        case .failed(let error):
                            Text(error).font(.system(size: 11)).foregroundStyle(.red)
                                .lineLimit(2).multilineTextAlignment(.leading)
                        case .ready(let reading):
                            readingView(reading)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tooltip)
                .accessibilityLabel("\(row.displayName). \(tooltip)")
            } else {
                Color.clear.frame(height: 42)
            }
        }
    }

    private func readingView(_ reading: GPUReading) -> some View {
        HStack(spacing: 10) {
            Text(reading.total.map { "\($0)%" } ?? "N/A")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .monospacedDigit().frame(width: 46, alignment: .trailing)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(reading.gpus) { gpu in GPURing(gpu: gpu) }
                }.padding(.vertical, 2)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tooltip: String {
        switch row.state {
        case .failed(let error): return "\(error)\nClick to retry."
        case .ready(let reading):
            return "Average across \(reading.gpus.count) GPUs. Updated \(reading.date.formatted(date: .omitted, time: .standard)). Click to refresh."
        case .loading(let previous):
            if let previous {
                return "Refreshing. Showing the reading from \(previous.date.formatted(date: .omitted, time: .standard))."
            }
            return "Querying GPU usage"
        case .idle: return "Querying GPU usage"
        }
    }
}

private struct GPURing: View {
    let gpu: GPU
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.09), lineWidth: 2.5)
            if let value = gpu.utilization {
                Circle().trim(from: 0, to: value / 100)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text(gpu.utilization.map { String(Int($0.rounded())) } ?? "–")
                .font(.system(size: 8, weight: .medium)).monospacedDigit()
                .foregroundStyle(gpu.utilization == nil ? .secondary : .primary)
        }
        .frame(width: 25, height: 25).padding(2)
        .help("GPU \(gpu.index): \(gpu.utilization.map { "\(Int($0.rounded()))%" } ?? "utilization unavailable")")
        .accessibilityLabel("GPU \(gpu.index), \(gpu.utilization.map { "\(Int($0.rounded())) percent" } ?? "unavailable")")
    }
}
