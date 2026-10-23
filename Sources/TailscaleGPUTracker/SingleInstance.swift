import AppKit
import Darwin

@MainActor
final class SingleInstance {
    static let showWindow = Notification.Name("io.qzgao.TailscaleGPUTracker.showWindow")
    private var descriptor: Int32 = -1

    func acquire() throws -> Bool {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("Tailscale GPU Tracker", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        descriptor = Darwin.open(directory.appendingPathComponent("instance.lock").path,
                                 O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
        let lockError = errno
        Darwin.close(descriptor)
        descriptor = -1
        guard lockError == EWOULDBLOCK else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(lockError)) }
        DistributedNotificationCenter.default().postNotificationName(Self.showWindow, object: nil,
                                                                      userInfo: nil, deliverImmediately: true)
        let existing = NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
            $0.executableURL?.lastPathComponent == "TailscaleGPUTracker"
        }
        existing?.activate(options: [.activateAllWindows])
        return false
    }
}
