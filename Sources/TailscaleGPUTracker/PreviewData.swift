#if DEBUG
import Foundation
import TrackerCore

/// Debug-only, isolated fixtures for visual checks. Neither closure opens a connection.
@MainActor
enum PreviewData {
    static func makeStore() -> MonitorStore {
        let defaults = UserDefaults(suiteName: "io.qzgao.TailscaleGPUTracker.preview")!
        defaults.removePersistentDomain(forName: "io.qzgao.TailscaleGPUTracker.preview")
        let preferences: [String: MachinePreferences] = [
            "atlas": .init(alias: "Atlas", username: "ubuntu", enabled: true),
            "boreal": .init(username: "root", enabled: true),
            "cedar": .init(alias: "Cedar", username: "research", enabled: true),
            "delta": .init(username: "ubuntu", enabled: true)
        ]
        defaults.set(try! JSONEncoder().encode(preferences), forKey: "machines")
        return MonitorStore(defaults: defaults, discover: {
            try TailnetSnapshot.parse(Data(#"""
            {"BackendState":"Running","CurrentTailnet":{"Name":"Preview · Sample machines"},"Peer":{
              "a":{"ID":"atlas","HostName":"atlas-station","DNSName":"atlas.example.ts.net.","Online":true},
              "b":{"ID":"boreal","HostName":"boreal","DNSName":"boreal.example.ts.net.","Online":true},
              "c":{"ID":"cedar","HostName":"cedar-cluster","DNSName":"cedar.example.ts.net.","Online":true},
              "d":{"ID":"delta","HostName":"delta","DNSName":"delta.example.ts.net.","Online":false},
              "e":{"ID":"echo","HostName":"echo","DNSName":"echo.example.ts.net.","Online":true}
            }}
            """#.utf8))
        }, fetchGPU: { machine, _ in
            try await Task.sleep(for: .seconds(machine.id == "boreal" ? 8 : 2))
            switch machine.id {
            case "atlas": return try GPUReading.parse("0, 92\n1, 86\n2, 100\n3, 82\n4, 90\n5, 95\n6, 75\n7, 100")
            case "boreal": return try GPUReading.parse("0, 0\n1, 24\n2, 50\n3, 0")
            default: return try GPUReading.parse("0, 64\n1, [N/A]")
            }
        })
    }
}
#endif
