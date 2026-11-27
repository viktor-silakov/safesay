import CryptoKit
import Darwin
import Dispatch
import Foundation

struct LaunchAgent {
    let storage: Storage

    private var label: String {
        let hash = SHA256.hash(data: Data(storage.home.path.utf8))
        let suffix = hash.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "local.safesay.worker.\(suffix)"
    }

    private var domain: String { "gui/\(getuid())" }
    private var target: String { "\(domain)/\(label)" }
    private var plist: URL {
        storage.home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    func register() throws {
        if try launchctl(["print", target]).status == 0 { return }

        try privateDirectory(storage.stateDirectory)
        try privateDirectory(storage.queueDirectory)
        try privateDirectory(plist.deletingLastPathComponent())
        guard let executable = Bundle.main.executableURL else {
            throw SafesayError("Cannot locate the safesay executable.")
        }
        let properties: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable.resolvingSymlinksInPath().path, "--worker", storage.home.path],
            "KeepAlive": true,
            "ThrottleInterval": 1,
            "StandardErrorPath": storage.stateDirectory.appendingPathComponent("worker.log").path,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0)
        try data.write(to: plist, options: .atomic)
        let result = try launchctl(["bootstrap", domain, plist.path])
        if result.status != 0, try launchctl(["print", target]).status != 0 {
            throw SafesayError("Could not register the LaunchAgent: \(result.output). Run from a macOS login session or select foreground mode.")
        }
    }

    func processQueue(speaker: Speaker) throws {
        let wakeups = DispatchSemaphore(value: 0)
        let queueWatcher = try watch(storage.queueDirectory, wakeups: wakeups)
        defer { queueWatcher.cancel() }
        let configWatcher = try watch(storage.configDirectory, wakeups: wakeups)
        defer { configWatcher.cancel() }
        while true {
            if try !storage.pendingJobs().isEmpty {
                try withLock(storage.speechLock) { try processNext(speaker: speaker) }
                continue
            }
            if try storage.withConfigurationLock({ try stopIfForeground() }) { return }
            _ = wakeups.wait(timeout: .now() + .seconds(5))
        }
    }

    private func stopIfForeground() throws -> Bool {
        guard try storage.configuration().mode == .foreground, try storage.pendingJobs().isEmpty else { return false }
        do {
            try FileManager.default.removeItem(at: plist)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // A prior shutdown may already have removed the file.
        }
        let result = try launchctl(["bootout", target])
        guard result.status == 0 else { throw SafesayError("Could not stop the LaunchAgent: \(result.output)") }
        return true
    }

    private func watch(_ directory: URL, wakeups: DispatchSemaphore) throws -> DispatchSourceFileSystemObject {
        let descriptor = open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write)
        source.setEventHandler { wakeups.signal() }
        source.setCancelHandler { close(descriptor) }
        source.activate()
        return source
    }

    private func processNext(speaker: Speaker) throws {
        guard let path = try storage.pendingJobs().first else { return }
        let data = try Data(contentsOf: path)
        let job: SpeechJob
        do {
            job = try JSONDecoder().decode(SpeechJob.self, from: data)
        } catch {
            let failed = storage.stateDirectory.appendingPathComponent("\(UUID()).invalid-job")
            try FileManager.default.moveItem(at: path, to: failed)
            report("Invalid queue entry \(path.lastPathComponent) moved to \(failed.lastPathComponent).")
            return
        }
        let status = try speaker.speak(job)
        if status != 0 { report("say exited with status \(status) for \(path.lastPathComponent).") }
        try FileManager.default.removeItem(at: path)
    }

    private func launchctl(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        task.standardOutput = output
        task.standardError = output
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
