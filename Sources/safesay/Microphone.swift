import AppKit
import CoreAudio
import Darwin
import Foundation

struct MicrophoneUser: Hashable {
    let pid: pid_t
    let identifier: String?
}

struct Microphone {
    static func users() throws -> [MicrophoneUser] {
        // A client can exit between enumerating the HAL objects and reading one.
        for _ in 0..<2 {
            if let users = try? readUsers() { return users }
        }
        return try readUsers()
    }

    private static func readUsers() throws -> [MicrophoneUser] {
        try AudioHardwareSystem.shared.processes.compactMap { process in
            guard try process.isRunningInput else { return nil }
            let pid = try process.pid
            let executable = executableURL(pid: pid)
            // For example, Chrome captures in a helper inside Google Chrome.app.
            let appID = executable.flatMap { containingApp(at: $0)?.bundleIdentifier }
            let identifier = appID
                ?? (try? process.bundleID).flatMap { $0.isEmpty ? nil : $0 }
                ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                ?? executable?.path
            return MicrophoneUser(pid: pid, identifier: identifier)
        }
        .sorted { $0.pid < $1.pid }
    }

    private static func executableURL(pid: pid_t) -> URL? {
        // PROC_PIDPATHINFO_MAXSIZE is a C macro Swift cannot import.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: path))
    }

    private static func containingApp(at executable: URL) -> Bundle? {
        var directory = executable.deletingLastPathComponent()
        var app: Bundle?
        while directory.path != "/" {
            if directory.pathExtension == "app", let bundle = Bundle(url: directory),
               bundle.bundleIdentifier != nil {
                app = bundle
            }
            directory.deleteLastPathComponent()
        }
        return app
    }
}
