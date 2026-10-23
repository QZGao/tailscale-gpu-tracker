import AppKit

let application = NSApplication.shared
let instance = SingleInstance()
do {
    guard try instance.acquire() else { exit(0) }
} catch {
    let alert = NSAlert()
    alert.messageText = "Unable to open Tailscale GPU Tracker"
    alert.informativeText = error.localizedDescription
    alert.runModal()
    exit(1)
}
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
