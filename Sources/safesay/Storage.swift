import Darwin
import Foundation

enum Mode: String, Codable {
    case foreground, background
}

struct Configuration: Codable {
    var mode: Mode?
    var allowedApps: Set<String> = []

    init() {}

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        mode = try fields.decodeIfPresent(Mode.self, forKey: .mode)
        allowedApps = Set(try fields.decodeIfPresent([String].self, forKey: .allowedApps) ?? [])
    }

    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encodeIfPresent(mode, forKey: .mode)
        try fields.encode(allowedApps.sorted(), forKey: .allowedApps)
    }

    private enum CodingKeys: String, CodingKey { case mode, allowedApps }
}

struct Storage {
    let home: URL
    let configDirectory: URL
    let stateDirectory: URL
    let queueDirectory: URL

    private var config: URL { configDirectory.appendingPathComponent("config.json") }
    private var configLock: URL { configDirectory.appendingPathComponent("config.lock") }
    private var queueLock: URL { stateDirectory.appendingPathComponent("queue.lock") }
    var speechLock: URL { stateDirectory.appendingPathComponent("speech.lock") }

    init(home: URL) {
        self.home = home.standardizedFileURL
        configDirectory = self.home.appendingPathComponent(".config/safesay", isDirectory: true)
        stateDirectory = self.home.appendingPathComponent("Library/Application Support/safesay", isDirectory: true)
        queueDirectory = stateDirectory.appendingPathComponent("queue", isDirectory: true)
    }

    func configuration() throws -> Configuration {
        do {
            return try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: config))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Configuration()
        }
    }

    func configure(_ update: (inout Configuration) throws -> Void) throws {
        try withConfigurationLock {
            var current = try configuration()
            let old = try encode(current)
            try update(&current)
            let new = try encode(current)
            if old != new { try new.write(to: config, options: .atomic) }
        }
    }

    func withConfigurationLock<T>(_ action: () throws -> T) throws -> T {
        try privateDirectory(configDirectory)
        return try withLock(configLock, perform: action)
    }

    func enqueue(_ job: SpeechJob) throws {
        try privateDirectory(queueDirectory)
        try withLock(queueLock) {
            let previous = try pendingJobs().last?.deletingPathExtension().lastPathComponent
            let sequence = (previous.flatMap(UInt64.init) ?? 0) + 1
            let name = String(format: "%020llu.job", sequence)
            let stage = stateDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: stage) }
            try encode(job).write(to: stage, options: .atomic)
            try FileManager.default.moveItem(at: stage, to: queueDirectory.appendingPathComponent(name))
        }
    }

    func pendingJobs() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: queueDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "job" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

func privateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
}

func withLock<T>(_ url: URL, perform: () throws -> T) throws -> T {
    let descriptor = open(url.path, O_CREAT | O_CLOEXEC | O_RDWR, 0o600)
    guard descriptor >= 0 else { throw posixError() }
    defer { close(descriptor) }
    while flock(descriptor, LOCK_EX) != 0 {
        guard errno == EINTR else { throw posixError() }
    }
    return try perform()
}

func posixError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}
