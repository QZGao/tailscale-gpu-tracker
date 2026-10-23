import AppKit
import TrackerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    #if DEBUG
    private let store = CommandLine.arguments.contains("--preview") ? PreviewData.makeStore() : MonitorStore()
    #else
    private let store = MonitorStore()
    #endif
    private var mainWindow: MainWindow?
    private var statusItem: NSStatusItem!
    private let statusLabel = StatusLabelView()

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenus()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showMachines),
            name: SingleInstance.showWindow, object: nil)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = ""
            statusLabel.frame = button.bounds
            statusLabel.autoresizingMask = [.width, .height]
            button.addSubview(statusLabel)
        }
        store.onChange = { [weak self] in self?.renderStatus() }
        renderStatus()
        showMachines()
        store.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMachines()
        return true
    }

    private func configureMenus() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        addAction("Show Machines", #selector(showMachines), key: "1", to: appMenu)
        appMenu.addItem(.separator())
        addAction("Quit Tailscale GPU Tracker", #selector(quit), key: "q", to: appMenu)
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        for (name, selector, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"),
                                       ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: name, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func renderStatus() {
        let rows = store.selectedRows
        statusLabel.entries = rows.map { row in
            StatusEntry(initial: String(row.displayName.prefix(1)).uppercased(), value: statusValue(row.state))
        }
        statusItem.length = statusLabel.requiredWidth
        let summary = rows.map { "\($0.displayName): \(statusValue($0.state))" }.joined(separator: " · ")
        statusItem.button?.toolTip = summary.isEmpty ? "Tailscale GPU Tracker" : summary
        statusItem.button?.setAccessibilityLabel(summary.isEmpty ? "Tailscale GPU Tracker. No machines selected." : summary)
        // Avoid replacing an open menu while a query completes.
        if !statusLabel.isMenuOpen { statusItem.menu = makeStatusMenu() }
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        addAction("Show Machines", #selector(showMachines), key: "1", to: menu)
        menu.addItem(.separator())
        if store.selectedRows.isEmpty {
            addInfo("Select machines in the main window", to: menu)
        } else {
            for row in store.selectedRows {
                let detail: String
                switch row.state {
                case .ready(let reading): detail = reading.total.map { "\($0)%" } ?? "Utilization unavailable"
                case .failed(let message): detail = message
                case .loading(let previous): detail = previous?.total.map { "\($0)%" } ?? "Querying…"
                case .idle: detail = "Querying…"
                }
                let item = addAction("\(row.displayName)   \(detail.replacingOccurrences(of: "\n", with: " ").prefix(100))",
                                     #selector(refreshMachine(_:)), key: "", to: menu)
                item.representedObject = row.id
                item.toolTip = detail
            }
        }
        menu.addItem(.separator())
        addInfo("Updates every minute", to: menu)
        menu.addItem(.separator())
        addAction("Quit Tailscale GPU Tracker", #selector(quit), key: "q", to: menu)
        return menu
    }

    private func statusValue(_ state: MonitorState) -> String {
        switch state {
        case .ready(let reading): return reading.total.map { "\($0)%" } ?? "N/A"
        case .failed: return "!"
        case .loading(let previous):
            guard let previous else { return "…" }
            return previous.total.map { "\($0)%" } ?? "N/A"
        case .idle: return "…"
        }
    }

    func menuWillOpen(_ menu: NSMenu) { statusLabel.isMenuOpen = true }
    func menuDidClose(_ menu: NSMenu) {
        statusLabel.isMenuOpen = false
        DispatchQueue.main.async { [weak self] in self?.renderStatus() }
    }

    @objc private func showMachines() {
        if mainWindow == nil { mainWindow = MainWindow(store: store) }
        mainWindow?.show()
    }

    @objc private func refreshMachine(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let row = store.rows.first(where: { $0.id == id }) else { return }
        store.refresh(row)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @discardableResult
    private func addAction(_ title: String, _ action: Selector, key: String, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    private func addInfo(_ text: String, to menu: NSMenu) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }
}
